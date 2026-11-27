package dev.wireddisplay.client.session

import dev.wireddisplay.client.protocol.Frame
import dev.wireddisplay.client.protocol.FrameFlags
import dev.wireddisplay.client.protocol.FrameHeader
import dev.wireddisplay.client.protocol.StreamType
import org.bouncycastle.crypto.digests.SHA256Digest
import org.bouncycastle.crypto.generators.HKDFBytesGenerator
import org.bouncycastle.crypto.params.Ed25519PrivateKeyParameters
import org.bouncycastle.crypto.params.Ed25519PublicKeyParameters
import org.bouncycastle.crypto.params.HKDFParameters
import org.bouncycastle.crypto.params.X25519PrivateKeyParameters
import org.bouncycastle.crypto.params.X25519PublicKeyParameters
import org.bouncycastle.crypto.signers.Ed25519Signer
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.MessageDigest
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

/**
 * Authenticated, encrypted channel matching Shared/Session/SecureChannel.swift (D-023).
 * Uses BouncyCastle for Ed25519/X25519/HKDF-SHA256 so API 29+ devices are supported uniformly.
 */
class SecureChannel(
    val role: PeerRole,
    identitySeed: ByteArray,
    ephemeralPrivateBytes: ByteArray? = null
) {
    sealed class ChannelError(message: String) : Exception(message) {
        object ExpectedAuthHello : ChannelError("expected authHello")
        object UnexpectedAuthHello : ChannelError("unexpected authHello")
        class IncompatibleVersion(val version: Int) : ChannelError("incompatible version $version")
        object WrongRole : ChannelError("wrong role")
        object InvalidKey : ChannelError("invalid key")
        object PlaintextAfterHandshake : ChannelError("plaintext after handshake")
        object EncryptedBeforeHandshake : ChannelError("encrypted before handshake")
        object DecryptFailed : ChannelError("decrypt failed")
        object BadProof : ChannelError("bad proof")
        object UnexpectedProof : ChannelError("unexpected proof")
        class NotVerified(val stream: StreamType) : ChannelError("not verified for $stream")
        object NotKeyed : ChannelError("not keyed")
        object PayloadTooLarge : ChannelError("payload too large")
    }

    data class Peer(
        val identityKey: ByteArray,
        val fingerprint: String,
        val pairingCode: String
    ) {
        override fun equals(other: Any?): Boolean =
            other is Peer && identityKey.contentEquals(other.identityKey) &&
                fingerprint == other.fingerprint && pairingCode == other.pairingCode

        override fun hashCode(): Int {
            var r = identityKey.contentHashCode()
            r = 31 * r + fingerprint.hashCode()
            r = 31 * r + pairingCode.hashCode()
            return r
        }
    }

    sealed class Incoming {
        object None : Incoming()
        data class SendProof(val payload: ByteArray) : Incoming()
        data class Verified(val peer: Peer) : Incoming()
        data class Message(val frame: Frame) : Incoming()
    }

    private val identityPriv = Ed25519PrivateKeyParameters(identitySeed, 0)
    private val identityPub = identityPriv.generatePublicKey().encoded
    private val ephemeralPriv = if (ephemeralPrivateBytes != null) {
        X25519PrivateKeyParameters(ephemeralPrivateBytes, 0)
    } else {
        X25519PrivateKeyParameters(SecureRandom())
    }
    private val ephemeralPub = ephemeralPriv.generatePublicKey().encoded
    private val localHello = AuthHello(
        protocolVersion = SessionConstants.PROTOCOL_VERSION,
        role = role,
        identityKey = identityPub,
        ephemeralKey = ephemeralPub
    )

    val authHelloPayload: ByteArray = SessionCodec.encode(ControlMessage.AuthHelloMsg(localHello))

    private val recvLock = Any()
    private val sendLock = Any()
    private var sendKey: ByteArray? = null
    private var receiveKey: ByteArray? = null
    private var transcript: ByteArray? = null
    private var peerHello: AuthHello? = null
    private var pairingCode: String = ""
    private var verifiedPeer: Peer? = null
    private var sentHello = false

    val peer: Peer?
        get() = synchronized(recvLock) { verifiedPeer }

    fun wire(
        stream: StreamType,
        keyframe: Boolean,
        sessionID: Long,
        sequence: Long,
        timestampNanos: Long,
        payload: ByteArray
    ): ByteArray = synchronized(sendLock) {
        if (!sentHello && stream == StreamType.CONTROL && payload.contentEquals(authHelloPayload)) {
            sentHello = true
            return@synchronized Frame.create(
                stream = stream,
                flags = FrameFlags.NONE,
                sessionID = sessionID,
                sequence = sequence,
                timestampNanos = timestampNanos,
                payload = payload
            ).encoded()
        }
        val key = sendKey
        if (key == null || !sentHello) throw ChannelError.NotKeyed
        if (payload.size > stream.maxPayloadLength - TAG_LENGTH) throw ChannelError.PayloadTooLarge

        var flags = FrameFlags.AUTHENTICATED
        if (keyframe) flags = flags or FrameFlags.KEYFRAME
        val header = FrameHeader(
            stream = stream,
            flags = flags,
            sessionID = sessionID,
            sequence = sequence,
            timestampNanos = timestampNanos,
            payloadLength = payload.size + TAG_LENGTH
        )
        val headerBytes = header.encoded()
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, nonce(stream, sequence)))
        cipher.updateAAD(headerBytes)
        val sealed = cipher.doFinal(payload)
        val out = ByteArray(headerBytes.size + sealed.size)
        System.arraycopy(headerBytes, 0, out, 0, headerBytes.size)
        System.arraycopy(sealed, 0, out, headerBytes.size, sealed.size)
        out
    }

    fun receive(frame: Frame): Incoming = synchronized(recvLock) {
        val key = receiveKey
        if (key == null) {
            if ((frame.header.flags and FrameFlags.AUTHENTICATED) != 0) {
                throw ChannelError.EncryptedBeforeHandshake
            }
            if (frame.header.stream != StreamType.CONTROL) throw ChannelError.ExpectedAuthHello
            val msg = SessionCodec.decodeControl(frame.payload)
            if (msg !is ControlMessage.AuthHelloMsg) throw ChannelError.ExpectedAuthHello
            return@synchronized Incoming.SendProof(keyed(msg.authHello))
        }
        if ((frame.header.flags and FrameFlags.AUTHENTICATED) == 0) {
            throw ChannelError.PlaintextAfterHandshake
        }
        if (frame.payload.size < TAG_LENGTH) throw ChannelError.DecryptFailed
        val plaintext = try {
            val cipher = Cipher.getInstance("AES/GCM/NoPadding")
            cipher.init(
                Cipher.DECRYPT_MODE,
                SecretKeySpec(key, "AES"),
                GCMParameterSpec(128, nonce(frame.header.stream, frame.header.sequence))
            )
            cipher.updateAAD(frame.header.encoded())
            cipher.doFinal(frame.payload)
        } catch (_: Exception) {
            throw ChannelError.DecryptFailed
        }

        val openedHeader = frame.header.copy(
            flags = frame.header.flags and FrameFlags.AUTHENTICATED.inv(),
            payloadLength = plaintext.size
        )
        val opened = Frame(openedHeader, plaintext)
        if (openedHeader.stream == StreamType.CONTROL) {
            when (val msg = SessionCodec.decodeControl(plaintext)) {
                is ControlMessage.AuthHelloMsg -> throw ChannelError.UnexpectedAuthHello
                is ControlMessage.AuthProof -> return@synchronized Incoming.Verified(verify(msg.signature))
                is ControlMessage.Ping, is ControlMessage.Pong, is ControlMessage.Bye ->
                    return@synchronized Incoming.Message(opened)
                else -> {}
            }
        }
        if (verifiedPeer == null) throw ChannelError.NotVerified(openedHeader.stream)
        Incoming.Message(opened)
    }

    private fun keyed(hello: AuthHello): ByteArray {
        if (hello.protocolVersion != SessionConstants.PROTOCOL_VERSION) {
            throw ChannelError.IncompatibleVersion(hello.protocolVersion)
        }
        if (hello.role == role) throw ChannelError.WrongRole
        if (hello.ephemeralKey.contentEquals(localHello.ephemeralKey)) throw ChannelError.InvalidKey

        val peerEphemeral = try {
            X25519PublicKeyParameters(hello.ephemeralKey, 0)
        } catch (_: Exception) {
            throw ChannelError.InvalidKey
        }
        try {
            Ed25519PublicKeyParameters(hello.identityKey, 0)
        } catch (_: Exception) {
            throw ChannelError.InvalidKey
        }
        val shared = ByteArray(32)
        ephemeralPriv.generateSecret(peerEphemeral, shared, 0)
        if (shared.all { it == 0.toByte() }) throw ChannelError.InvalidKey

        val host = if (role == PeerRole.HOST) localHello else hello
        val client = if (role == PeerRole.HOST) hello else localHello
        val md = MessageDigest.getInstance("SHA-256")
        md.update("WiredDisplay auth v2".toByteArray(Charsets.UTF_8))
        md.update(SessionCodec.encode(ControlMessage.AuthHelloMsg(host)))
        md.update(SessionCodec.encode(ControlMessage.AuthHelloMsg(client)))
        val digest = md.digest()

        val hostToClient = hkdf(shared, digest, "host->client", 32)
        val clientToHost = hkdf(shared, digest, "client->host", 32)
        synchronized(sendLock) {
            sendKey = if (role == PeerRole.HOST) hostToClient else clientToHost
        }
        receiveKey = if (role == PeerRole.HOST) clientToHost else hostToClient

        val codeBytes = hkdf(shared, digest, "pairing code", 8)
        var rawCode = 0L
        for (b in codeBytes) {
            rawCode = (rawCode shl 8) or (b.toLong() and 0xFFL)
        }
        // Unsigned modulo matches Swift UInt64 % 1_000_000 when the top bit is set.
        val codeMod = java.lang.Long.remainderUnsigned(rawCode, 1_000_000L)
        val digits = String.format("%06d", codeMod)
        pairingCode = "${digits.substring(0, 3)} ${digits.substring(3, 6)}"
        transcript = digest
        peerHello = hello

        val signer = Ed25519Signer()
        signer.init(true, identityPriv)
        val msg = proofMessage(role, digest)
        signer.update(msg, 0, msg.size)
        return SessionCodec.encode(ControlMessage.AuthProof(signer.generateSignature()))
    }

    private fun verify(signature: ByteArray): Peer {
        val tr = transcript
        val ph = peerHello
        if (verifiedPeer != null || tr == null || ph == null) throw ChannelError.UnexpectedProof
        val pub = try {
            Ed25519PublicKeyParameters(ph.identityKey, 0)
        } catch (_: Exception) {
            throw ChannelError.BadProof
        }
        val verifier = Ed25519Signer()
        verifier.init(false, pub)
        val msg = proofMessage(ph.role, tr)
        verifier.update(msg, 0, msg.size)
        if (!verifier.verifySignature(signature)) throw ChannelError.BadProof
        val peer = Peer(ph.identityKey, fingerprint(ph.identityKey), pairingCode)
        verifiedPeer = peer
        return peer
    }

    companion object {
        const val TAG_LENGTH: Int = 16

        fun proofMessage(role: PeerRole, transcript: ByteArray): ByteArray {
            val prefix = "WiredDisplay proof v2".toByteArray(Charsets.UTF_8)
            val out = ByteArray(prefix.size + 1 + transcript.size)
            System.arraycopy(prefix, 0, out, 0, prefix.size)
            out[prefix.size] = role.rawValue.toByte()
            System.arraycopy(transcript, 0, out, prefix.size + 1, transcript.size)
            return out
        }

        fun fingerprint(publicKey: ByteArray): String {
            val digest = MessageDigest.getInstance("SHA-256").digest(publicKey)
            return digest.take(8).joinToString("") { String.format("%02x", it) }
        }

        fun hkdf(ikm: ByteArray, salt: ByteArray, info: String, length: Int): ByteArray {
            val gen = HKDFBytesGenerator(SHA256Digest())
            gen.init(HKDFParameters(ikm, salt, info.toByteArray(Charsets.UTF_8)))
            val out = ByteArray(length)
            gen.generateBytes(out, 0, length)
            return out
        }

        fun nonce(stream: StreamType, sequence: Long): ByteArray {
            val buf = ByteBuffer.allocate(12).order(ByteOrder.BIG_ENDIAN)
            buf.put(stream.rawValue.toByte())
            buf.put(0)
            buf.put(0)
            buf.put(0)
            buf.putLong(sequence)
            return buf.array()
        }
    }
}

/** Assigns per-stream monotonic sequence numbers and seals frames through SecureChannel. */
class SessionFramer(
    val sessionID: Long,
    private val channel: SecureChannel? = null,
    private val clock: () -> Long = { System.nanoTime() }
) {
    private val sequences = HashMap<StreamType, Long>()
    private val lock = Any()

    fun frame(
        stream: StreamType,
        payload: ByteArray,
        keyframe: Boolean = false,
        timestampNanos: Long? = null
    ): ByteArray = synchronized(lock) {
        val seq = sequences[stream] ?: 0L
        sequences[stream] = seq + 1L
        val ts = timestampNanos ?: clock()
        val ch = channel
        if (ch != null) {
            ch.wire(stream, keyframe, sessionID, seq, ts, payload)
        } else {
            val flags = if (keyframe) FrameFlags.KEYFRAME else FrameFlags.NONE
            Frame.create(stream, flags, sessionID, seq, ts, payload).encoded()
        }
    }
}

class DecodeFailureDetector(
    private val threshold: Int = 3,
    private val windowSeconds: Double = 10.0,
    private val cooldownSeconds: Double = 8.0
) {
    private val failures = ArrayList<Double>()
    private var lastReport = Double.NEGATIVE_INFINITY

    fun failed(atSeconds: Double): Boolean {
        if (atSeconds - lastReport < cooldownSeconds) return false
        failures.add(atSeconds)
        failures.removeAll { atSeconds - it > windowSeconds }
        if (failures.size < threshold) return false
        failures.clear()
        lastReport = atSeconds
        return true
    }

    fun reset() {
        failures.clear()
    }
}

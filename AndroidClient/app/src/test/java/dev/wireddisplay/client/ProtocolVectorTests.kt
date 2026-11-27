package dev.wireddisplay.client

import dev.wireddisplay.client.audio.AudioJitterBuffer
import dev.wireddisplay.client.input.CoordinateMapper
import dev.wireddisplay.client.input.EditGesture
import dev.wireddisplay.client.input.PointF
import dev.wireddisplay.client.input.ShortcutRemapper
import dev.wireddisplay.client.input.TouchInterpreter
import dev.wireddisplay.client.protocol.Frame
import dev.wireddisplay.client.protocol.FrameError
import dev.wireddisplay.client.protocol.FrameFlags
import dev.wireddisplay.client.protocol.FrameHeader
import dev.wireddisplay.client.protocol.FrameParser
import dev.wireddisplay.client.protocol.SequenceValidator
import dev.wireddisplay.client.protocol.StreamType
import dev.wireddisplay.client.session.AudioPacket
import dev.wireddisplay.client.session.CodecFlags
import dev.wireddisplay.client.session.ControlMessage
import dev.wireddisplay.client.session.CursorImage
import dev.wireddisplay.client.session.Hello
import dev.wireddisplay.client.session.InputEvent
import dev.wireddisplay.client.session.MomentumPhase
import dev.wireddisplay.client.session.PeerRole
import dev.wireddisplay.client.session.PointerButton
import dev.wireddisplay.client.session.PointerPhase
import dev.wireddisplay.client.session.ScrollPhase
import dev.wireddisplay.client.session.SecureChannel
import dev.wireddisplay.client.session.SessionCodec
import dev.wireddisplay.client.session.StreamConfig
import dev.wireddisplay.client.session.VideoCodec
import org.bouncycastle.crypto.params.Ed25519PrivateKeyParameters
import org.bouncycastle.crypto.params.X25519PrivateKeyParameters
import org.bouncycastle.crypto.params.X25519PublicKeyParameters
import org.bouncycastle.crypto.signers.Ed25519Signer
import org.json.JSONObject
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.File
import java.security.MessageDigest

/**
 * Verifies the Kotlin protocol, framing, and SecureChannel implementation byte-for-byte
 * against the repository's golden Tests/Vectors/protocol-v6.json file.
 */
class ProtocolVectorTests {

    private fun loadVectors(): JSONObject {
        val candidates = listOf(
            File("../Tests/Vectors/protocol-v6.json"),
            File("../../Tests/Vectors/protocol-v6.json"),
            File("Tests/Vectors/protocol-v6.json")
        )
        val file = candidates.firstOrNull { it.exists() }
            ?: error("Could not locate Tests/Vectors/protocol-v6.json from ${File(".").absolutePath}")
        return JSONObject(file.readText())
    }

    private fun hex(text: String): ByteArray {
        require(text.length % 2 == 0)
        return ByteArray(text.length / 2) { i ->
            text.substring(i * 2, i * 2 + 2).toInt(16).toByte()
        }
    }

    private fun parseSingleFrame(wire: ByteArray): Frame {
        val parser = FrameParser()
        parser.append(wire)
        val frame = parser.next()
        assertNotNull("incomplete frame", frame)
        assertNull(parser.next())
        return frame!!
    }

    private fun u64Hex(text: String): Long = java.lang.Long.parseUnsignedLong(text, 16)

    @Test
    fun controlMessagesMatchGoldenVectors() {
        val vectors = loadVectors()
        val control = vectors.getJSONObject("control")
        val messages = mapOf<String, ControlMessage>(
            "hello" to ControlMessage.HelloMsg(
                Hello(6, PeerRole.CLIENT, "Tab \u00DCn\u00EF 11", 2560, 1600, 2, 120, CodecFlags.H264 or CodecFlags.HEVC, 274)
            ),
            "streamConfig" to ControlMessage.StreamConfigMsg(
                StreamConfig(2560, 1600, 1440, 900, 60, VideoCodec.HEVC)
            ),
            "requestKeyframe" to ControlMessage.RequestKeyframe,
            "ping" to ControlMessage.Ping(u64Hex("fedcba9876543210")),
            "pong" to ControlMessage.Pong(u64Hex("0123456789abcdef")),
            "bye" to ControlMessage.Bye("selesai"),
            "audioRoute_speaker" to ControlMessage.AudioRoute(speaker = true, microphone = false),
            "audioRoute_both" to ControlMessage.AudioRoute(speaker = true, microphone = true),
            "videoActive_false" to ControlMessage.VideoActive(false),
            "decodeFailed" to ControlMessage.DecodeFailed,
            "brightness" to ControlMessage.Brightness(0.75f),
            "cursor" to ControlMessage.Cursor(0.25f, 0.5f, true),
            "cursorImage" to ControlMessage.CursorImageMsg(
                CursorImage(byteArrayOf(0x89.toByte(), 0x50, 0x4E, 0x47), 0.015625f, 0.03125f, 0.125f, 0f)
            ),
            "panelSize" to ControlMessage.PanelSize(1600, 2560)
        )

        for ((name, msg) in messages) {
            val expected = hex(control.getString(name))
            assertArrayEquals("encode $name", expected, SessionCodec.encode(msg))
            assertEquals("decode $name", msg, SessionCodec.decodeControl(expected))
        }

        val longHello = Hello(6, PeerRole.CLIENT, "\u00E9".repeat(40), 2400, 1080, 3, 90, CodecFlags.H264, 0)
        val expectedTrunc = hex(control.getString("hello_name_truncated"))
        assertArrayEquals(expectedTrunc, SessionCodec.encode(ControlMessage.HelloMsg(longHello)))
        assertEquals(
            ControlMessage.HelloMsg(longHello.copy(deviceName = "\u00E9".repeat(32))),
            SessionCodec.decodeControl(expectedTrunc)
        )
    }

    @Test
    fun inputEventsMatchGoldenVectors() {
        val vectors = loadVectors()
        val input = vectors.getJSONObject("input")
        val events = mapOf<String, InputEvent>(
            "pointer_move" to InputEvent.Pointer(PointerPhase.MOVE, PointerButton.NONE, 0.5f, 0.25f),
            "pointer_down_left" to InputEvent.Pointer(PointerPhase.DOWN, PointerButton.LEFT, 1f, 0f),
            "pointer_up_right" to InputEvent.Pointer(PointerPhase.UP, PointerButton.RIGHT, 0.125f, 0.875f),
            "scroll" to InputEvent.Scroll(-12.5f, 40f),
            "releaseAll" to InputEvent.ReleaseAll,
            "key_a_down" to InputEvent.Key(0x04, true),
            "key_rightCommand_up" to InputEvent.Key(0xE7, false),
            "gestureScroll_changed" to InputEvent.GestureScroll(1.5f, -3f, ScrollPhase.CHANGED, MomentumPhase.NONE),
            "gestureScroll_momentum" to InputEvent.GestureScroll(0f, 6.25f, ScrollPhase.NONE, MomentumPhase.CONTINUE),
            "magnify_began" to InputEvent.Magnify(0.0625f, ScrollPhase.BEGAN),
            "rotate_ended" to InputEvent.Rotate(-15f, ScrollPhase.ENDED)
        )
        for ((name, ev) in events) {
            val expected = hex(input.getString(name))
            assertArrayEquals("encode $name", expected, SessionCodec.encode(ev))
            assertEquals("decode $name", ev, SessionCodec.decodeInput(expected))
        }
    }

    @Test
    fun audioPacketsAreLittleEndian() {
        val audio = loadVectors().getJSONObject("audio")
        for (name in audio.keys()) {
            val entry = audio.getJSONObject(name)
            val channels = entry.getInt("channels")
            val jsonSamples = entry.getJSONArray("samples")
            val samples = ShortArray(jsonSamples.length()) { jsonSamples.getInt(it).toShort() }
            val expected = hex(entry.getString("hex"))
            val pkt = AudioPacket(channels, samples)
            assertArrayEquals("encode $name", expected, pkt.encoded())
            assertEquals("decode $name", pkt, AudioPacket.decode(expected, channels))
        }
    }

    @Test
    fun keyDerivationAndUnsignedPairingCodeMatchVectors() {
        val vectors = loadVectors()
        val keys = vectors.getJSONObject("keys")
        val hs = vectors.getJSONObject("handshake")

        val hostEph = X25519PrivateKeyParameters(hex(keys.getString("hostEphemeralPrivate")), 0)
        val clientEphPub = X25519PublicKeyParameters(hex(keys.getString("clientEphemeralPublic")), 0)
        assertArrayEquals(hex(keys.getString("hostEphemeralPublic")), hostEph.generatePublicKey().encoded)

        val shared = ByteArray(32)
        hostEph.generateSecret(clientEphPub, shared, 0)
        assertArrayEquals(hex(hs.getString("sharedSecret")), shared)

        val md = MessageDigest.getInstance("SHA-256")
        md.update("WiredDisplay auth v2".toByteArray(Charsets.UTF_8))
        md.update(hex(hs.getString("hostAuthHelloPayload")))
        md.update(hex(hs.getString("clientAuthHelloPayload")))
        val transcript = md.digest()
        assertArrayEquals(hex(hs.getString("transcript")), transcript)

        assertArrayEquals(hex(hs.getString("hostToClientKey")), SecureChannel.hkdf(shared, transcript, "host->client", 32))
        assertArrayEquals(hex(hs.getString("clientToHostKey")), SecureChannel.hkdf(shared, transcript, "client->host", 32))
        val codeBytes = SecureChannel.hkdf(shared, transcript, "pairing code", 8)
        assertArrayEquals(hex(hs.getString("pairingCodeBytes")), codeBytes)
        var rawCode = 0L
        for (b in codeBytes) rawCode = (rawCode shl 8) or (b.toLong() and 0xFFL)
        assertEquals(hs.getString("pairingCodeUnsigned"), java.lang.Long.toUnsignedString(rawCode))
    }

    @Test
    fun clientSideHandshakeAndFramesMatchGoldenVectors() {
        val vectors = loadVectors()
        val keys = vectors.getJSONObject("keys")
        val hs = vectors.getJSONObject("handshake")
        val session = vectors.getJSONObject("session")
        val frames = vectors.getJSONObject("frames")
        val plaintexts = vectors.getJSONObject("framePlaintexts")

        val clientSeed = hex(keys.getString("clientIdentitySeed"))
        val clientEph = hex(keys.getString("clientEphemeralPrivate"))
        val client = SecureChannel(PeerRole.CLIENT, clientSeed, clientEph)
        val clientSid = u64Hex(session.getString("clientSessionID"))
        val baseTs = u64Hex(session.getString("baseTimestamp"))

        assertArrayEquals(hex(hs.getString("clientAuthHelloPayload")), client.authHelloPayload)
        assertArrayEquals(
            hex(frames.getString("client_auth_hello")),
            client.wire(StreamType.CONTROL, false, clientSid, 0L, baseTs + 10L, client.authHelloPayload)
        )

        val sendProof = client.receive(parseSingleFrame(hex(frames.getString("host_auth_hello"))))
        assertTrue(sendProof is SecureChannel.Incoming.SendProof)
        val proofMsg = SessionCodec.decodeControl((sendProof as SecureChannel.Incoming.SendProof).payload)
        assertTrue(proofMsg is ControlMessage.AuthProof)
        val pub = Ed25519PrivateKeyParameters(clientSeed, 0).generatePublicKey()
        val verifier = Ed25519Signer().apply { init(false, pub) }
        val expectedMsg = hex(hs.getString("clientProofMessage"))
        verifier.update(expectedMsg, 0, expectedMsg.size)
        assertTrue(verifier.verifySignature((proofMsg as ControlMessage.AuthProof).signature))

        val verified = client.receive(parseSingleFrame(hex(frames.getString("host_proof"))))
        assertTrue(verified is SecureChannel.Incoming.Verified)
        val peer = (verified as SecureChannel.Incoming.Verified).peer
        assertArrayEquals(hex(keys.getString("hostIdentityPublic")), peer.identityKey)
        assertEquals(hs.getString("hostFingerprint"), peer.fingerprint)
        assertEquals(hs.getString("pairingCode"), peer.pairingCode)

        assertArrayEquals(
            hex(frames.getString("client_input")),
            client.wire(StreamType.INPUT, false, clientSid, 0L, baseTs + 12L, hex(plaintexts.getString("client_input")))
        )
        assertArrayEquals(
            hex(frames.getString("client_microphone")),
            client.wire(StreamType.MICROPHONE, false, clientSid, 0L, baseTs + 13L, hex(plaintexts.getString("client_microphone")))
        )

        val ping = client.receive(parseSingleFrame(hex(frames.getString("host_ping"))))
        assertTrue(ping is SecureChannel.Incoming.Message)
        assertArrayEquals(hex(plaintexts.getString("host_ping")), (ping as SecureChannel.Incoming.Message).frame.payload)

        val video = client.receive(parseSingleFrame(hex(frames.getString("host_video_keyframe"))))
        assertTrue(video is SecureChannel.Incoming.Message)
        val vf = (video as SecureChannel.Incoming.Message).frame
        assertEquals(FrameFlags.KEYFRAME, vf.header.flags)
        assertEquals(u64Hex(session.getString("videoSequence")), vf.header.sequence)
        assertArrayEquals(hex(plaintexts.getString("host_video_keyframe")), vf.payload)
    }

    @Test
    fun tamperedAndMalformedFramesAreRejected() {
        val vectors = loadVectors()
        val keys = vectors.getJSONObject("keys")
        val frames = vectors.getJSONObject("frames")
        val host = SecureChannel(
            PeerRole.HOST,
            hex(keys.getString("hostIdentitySeed")),
            hex(keys.getString("hostEphemeralPrivate"))
        )
        host.wire(StreamType.CONTROL, false, 1L, 0L, 0L, host.authHelloPayload)
        host.receive(parseSingleFrame(hex(frames.getString("client_auth_hello"))))
        host.receive(parseSingleFrame(hex(frames.getString("client_proof"))))

        val wire = hex(frames.getString("client_input"))
        wire[FrameHeader.ENCODED_LENGTH] = (wire[FrameHeader.ENCODED_LENGTH].toInt() xor 0x01).toByte()
        try {
            host.receive(parseSingleFrame(wire))
            fail("tampered ciphertext must fail")
        } catch (_: SecureChannel.ChannelError.DecryptFailed) {
        }

        // Bad magic poisons the parser.
        val badParser = FrameParser()
        badParser.append(ByteArray(FrameHeader.ENCODED_LENGTH) { 0x42 })
        try {
            badParser.next()
            fail("bad magic must throw")
        } catch (_: FrameError.BadMagic) {
        }
        try {
            badParser.append(byteArrayOf(1, 2, 3))
            fail("poisoned parser must reject subsequent bytes")
        } catch (_: FrameError.ParserPoisoned) {
        }

        // Sequence replay is rejected.
        val validator = SequenceValidator(42L)
        validator.accept(FrameHeader(StreamType.CONTROL, 0, 42L, 0L, 0L, 0))
        try {
            validator.accept(FrameHeader(StreamType.CONTROL, 0, 42L, 0L, 0L, 0))
            fail("replayed sequence must fail")
        } catch (_: FrameError.ReplayedOrReordered) {
        }
    }

    @Test
    fun inputAndAudioHelpersBehaveCorrectly() {
        val mapper = CoordinateMapper.create(1000f, 500f, 1000f, 1000f)!!
        assertNull(mapper.normalized(100f, 250f)) // pillarbox
        assertEquals(PointF(0.5f, 0.5f), mapper.normalized(500f, 250f))

        val ti = TouchInterpreter(slopPx = 10f)
        ti.began(PointF(100f, 100f), PointF(0.5f, 0.5f), 1.0)
        val tapEvents = ti.ended(1.1)
        assertEquals(3, tapEvents.size)

        val remapper = ShortcutRemapper()
        assertEquals(listOf(InputEvent.Key(0xE0, true)), remapper.key(0xE0, true))
        val remapped = remapper.key(0x2B, true)
        assertEquals(
            listOf(InputEvent.Key(0xE0, false), InputEvent.Key(0xE3, true), InputEvent.Key(0x2B, true)),
            remapped
        )

        assertEquals(EditGesture.COPY, EditGesture.classify(100f, 60f, 0f, 0f, null, 10.0))
        assertEquals(EditGesture.CUT, EditGesture.classify(100f, 60f, 0f, 0f, EditGesture.COPY, 0.5))
        assertEquals(EditGesture.PASTE, EditGesture.classify(100f, 150f, 0f, 0f, null, 10.0))

        val jitter = AudioJitterBuffer(channels = 2, targetFrames = 4, maxFrames = 16)
        jitter.push(AudioPacket(2, shortArrayOf(100, -100, 200, -200, 300, -300, 400, -400)))
        val out = ShortArray(8)
        jitter.pullInterleaved(out, 4)
        assertEquals(100.toShort(), out[0])
        assertEquals((-400).toShort(), out[7])
    }
}

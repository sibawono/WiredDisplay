package dev.wireddisplay.client.session

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import org.bouncycastle.crypto.params.Ed25519PrivateKeyParameters
import org.json.JSONArray
import org.json.JSONObject
import java.security.KeyStore
import java.security.SecureRandom
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

data class TrustedPeer(
    val identityKey: ByteArray,
    val fingerprint: String,
    val name: String
) {
    override fun equals(other: Any?): Boolean =
        other is TrustedPeer && identityKey.contentEquals(other.identityKey) &&
            fingerprint == other.fingerprint && name == other.name

    override fun hashCode(): Int {
        var r = identityKey.contentHashCode()
        r = 31 * r + fingerprint.hashCode()
        r = 31 * r + name.hashCode()
        return r
    }
}

/**
 * Stores this device's long-term Ed25519 identity seed (wrapped with an Android Keystore AES-GCM key)
 * and the list of paired Macs.
 */
class TrustStore(context: Context) {
    private val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
    private val lock = Any()

    fun identitySeed(): ByteArray = synchronized(lock) {
        val existing = prefs.getString(KEY_IDENTITY, null)
        if (existing != null) {
            try {
                val decrypted = decryptSeed(existing)
                if (decrypted.size == 32) return@synchronized decrypted
            } catch (_: Exception) {
                // Regenerate below if keystore key was invalidated.
            }
        }
        val seed = ByteArray(32).also { SecureRandom().nextBytes(it) }
        prefs.edit().putString(KEY_IDENTITY, encryptSeed(seed)).apply()
        seed
    }

    fun identityPublicKey(): ByteArray {
        val priv = Ed25519PrivateKeyParameters(identitySeed(), 0)
        return priv.generatePublicKey().encoded
    }

    val peers: List<TrustedPeer>
        get() = synchronized(lock) { loadPeers() }

    fun isTrusted(identityKey: ByteArray): Boolean = synchronized(lock) {
        loadPeers().any { it.identityKey.contentEquals(identityKey) }
    }

    fun trust(identityKey: ByteArray, name: String) = synchronized(lock) {
        val current = loadPeers().toMutableList()
        val fp = SecureChannel.fingerprint(identityKey)
        val idx = current.indexOfFirst { it.identityKey.contentEquals(identityKey) }
        val entry = TrustedPeer(identityKey, fp, name)
        if (idx >= 0) current[idx] = entry else current.add(entry)
        savePeers(current)
    }

    fun rename(identityKey: ByteArray, name: String) = synchronized(lock) {
        val current = loadPeers().toMutableList()
        val idx = current.indexOfFirst { it.identityKey.contentEquals(identityKey) }
        if (idx >= 0 && current[idx].name != name) {
            current[idx] = current[idx].copy(name = name)
            savePeers(current)
        }
    }

    fun forgetAllPeers() = synchronized(lock) {
        prefs.edit().remove(KEY_PEERS).apply()
    }

    private fun loadPeers(): List<TrustedPeer> {
        val raw = prefs.getString(KEY_PEERS, null) ?: return emptyList()
        return try {
            val arr = JSONArray(raw)
            val list = ArrayList<TrustedPeer>(arr.length())
            for (i in 0 until arr.length()) {
                val obj = arr.getJSONObject(i)
                val keyBytes = Base64.decode(obj.getString("key"), Base64.NO_WRAP)
                val fp = obj.optString("fp", SecureChannel.fingerprint(keyBytes))
                val name = obj.optString("name", "Mac")
                list.add(TrustedPeer(keyBytes, fp, name))
            }
            list
        } catch (_: Exception) {
            emptyList()
        }
    }

    private fun savePeers(list: List<TrustedPeer>) {
        val arr = JSONArray()
        for (peer in list) {
            val obj = JSONObject()
            obj.put("key", Base64.encodeToString(peer.identityKey, Base64.NO_WRAP))
            obj.put("fp", peer.fingerprint)
            obj.put("name", peer.name)
            arr.put(obj)
        }
        prefs.edit().putString(KEY_PEERS, arr.toString()).apply()
    }

    private fun getOrCreateKeystoreKey(): SecretKey {
        val ks = KeyStore.getInstance(KEYSTORE_PROVIDER).apply { load(null) }
        (ks.getKey(KEY_ALIAS, null) as? SecretKey)?.let { return it }
        val gen = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, KEYSTORE_PROVIDER)
        gen.init(
            KeyGenParameterSpec.Builder(
                KEY_ALIAS,
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)
                .build()
        )
        return gen.generateKey()
    }

    private fun encryptSeed(seed: ByteArray): String {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, getOrCreateKeystoreKey())
        val iv = cipher.iv
        val ct = cipher.doFinal(seed)
        val combined = ByteArray(1 + iv.size + ct.size)
        combined[0] = iv.size.toByte()
        System.arraycopy(iv, 0, combined, 1, iv.size)
        System.arraycopy(ct, 0, combined, 1 + iv.size, ct.size)
        return Base64.encodeToString(combined, Base64.NO_WRAP)
    }

    private fun decryptSeed(encoded: String): ByteArray {
        val combined = Base64.decode(encoded, Base64.NO_WRAP)
        val ivLen = combined[0].toInt() and 0xFF
        val iv = combined.copyOfRange(1, 1 + ivLen)
        val ct = combined.copyOfRange(1 + ivLen, combined.size)
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, getOrCreateKeystoreKey(), GCMParameterSpec(128, iv))
        return cipher.doFinal(ct)
    }

    companion object {
        private const val PREFS_NAME = "wd_trust_store"
        private const val KEY_IDENTITY = "identity_seed_v1"
        private const val KEY_PEERS = "trusted_peers_v1"
        private const val KEYSTORE_PROVIDER = "AndroidKeyStore"
        private const val KEY_ALIAS = "dev.wireddisplay.client.identity_wrap"
    }
}

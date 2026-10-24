package org.cortege.app

import android.content.Context
import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.security.keystore.StrongBoxUnavailableException
import java.io.File
import java.nio.ByteBuffer
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * Garde un secret de 32 octets par emplacement du coffre, chiffré par une clé qui
 * ne quitte pas le Keystore Android (StrongBox si le téléphone en a un). Le coffre
 * mélange ce secret au code PIN : copier les fichiers sur un autre ordinateur ne
 * suffit donc pas pour deviner le PIN hors ligne.
 *
 * Effacer les secrets rend le coffre définitivement illisible, même avec le bon PIN.
 * Les deux emplacements ont toujours un secret, même quand l'un des deux est du
 * bruit : leur présence ne dit rien.
 *
 * Renouvellement : quand des données sont effacées, l'appli remplace le secret de
 * l'emplacement par un nouveau, réécrit le coffre avec la nouvelle clé, puis
 * détruit l'ancien secret et sa clé Keystore. Les vieilles copies du fichier,
 * restées dans la mémoire flash, deviennent illisibles. Pour qu'une coupure en
 * plein renouvellement ne fasse jamais perdre le coffre, un emplacement peut
 * garder deux secrets (générations 0 et 1) le temps de l'opération : le plus
 * récent est essayé en premier, et l'appli supprime l'autre dès qu'elle sait
 * lequel ouvre le coffre. La génération 2 est l'ancien format, un seul secret
 * sans compteur.
 */
class HardwareSecret(private val context: Context) {
    /** Les secrets d'un emplacement, du plus récent au plus ancien : (génération, secret). */
    fun loadAll(slot: Int): List<Pair<Int, ByteArray>> {
        val found = ArrayList<Triple<Long, Int, ByteArray>>()
        for (generation in GENERATIONS) {
            val entry = read(slot, generation) ?: continue
            found.add(Triple(entry.first, generation, entry.second))
        }
        return found.sortedByDescending { it.first }.map { Pair(it.second, it.third) }
    }

    /** Remplace tout ce que l'emplacement gardait par ce secret. Rend sa génération. */
    fun store(slot: Int, secret: ByteArray): Int {
        for (generation in GENERATIONS) remove(slot, generation)
        write(slot, 0, 1L, secret)
        return 0
    }

    /**
     * Ajoute un secret plus récent à côté de l'actuel, sans toucher à celui-ci.
     * Refuse s'il y en a déjà deux : l'appelant doit d'abord n'en garder qu'un.
     */
    fun rotate(slot: Int, secret: ByteArray): Int {
        val existing = GENERATIONS.mapNotNull { generation ->
            read(slot, generation)?.let { Pair(generation, it.first) }
        }
        if (existing.size != 1) throw IllegalStateException("un seul secret attendu")
        val (current, counter) = existing[0]
        val target = if (current == 0) 1 else 0
        write(slot, target, counter + 1, secret)
        return target
    }

    /** Détruit les secrets de cet emplacement autres que [generation], clé Keystore comprise. */
    fun keepOnly(slot: Int, generation: Int) {
        for (other in GENERATIONS) {
            if (other != generation) remove(slot, other)
        }
    }

    fun eraseAll() {
        for (slot in SLOTS) {
            for (generation in GENERATIONS) remove(slot, generation)
        }
    }

    private fun blobFile(slot: Int, generation: Int) =
        if (generation == LEGACY) File(context.filesDir, "hw$slot.bin")
        else File(context.filesDir, "hw${slot}_$generation.bin")

    private fun alias(slot: Int, generation: Int) =
        if (generation == LEGACY) "cortege_hw_wrap_$slot" else "cortege_hw_wrap_${slot}_$generation"

    private fun keyStore(): KeyStore = KeyStore.getInstance(KEYSTORE).apply { load(null) }

    private fun deleteKey(slot: Int, generation: Int) {
        val ks = keyStore()
        if (ks.containsAlias(alias(slot, generation))) ks.deleteEntry(alias(slot, generation))
    }

    private fun existingKey(slot: Int, generation: Int): SecretKey? =
        keyStore().getKey(alias(slot, generation), null) as? SecretKey

    private fun remove(slot: Int, generation: Int) {
        deleteKey(slot, generation)
        val file = blobFile(slot, generation)
        file.delete()
        File(context.filesDir, "${file.name}.tmp").delete()
    }

    /** (compteur, secret), ou null si rien n'est gardé ou si la clé Keystore a disparu. */
    private fun read(slot: Int, generation: Int): Pair<Long, ByteArray>? {
        val file = blobFile(slot, generation)
        if (!file.exists()) return null
        val key = existingKey(slot, generation) ?: return null
        val sealed = file.readBytes()
        if (sealed.size <= IV_BYTES) return null
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(
            Cipher.DECRYPT_MODE,
            key,
            GCMParameterSpec(TAG_BITS, sealed, 0, IV_BYTES),
        )
        val plain = cipher.doFinal(sealed, IV_BYTES, sealed.size - IV_BYTES)
        return if (plain.size == COUNTER_BYTES + SECRET_BYTES) {
            Pair(ByteBuffer.wrap(plain, 0, COUNTER_BYTES).long, plain.copyOfRange(COUNTER_BYTES, plain.size))
        } else {
            // Ancien format : le secret seul.
            Pair(0L, plain)
        }
    }

    private fun write(slot: Int, generation: Int, counter: Long, secret: ByteArray) {
        // Une clé Keystore neuve à chaque écriture : un ancien secret retrouvé dans
        // la mémoire flash ne pourrait plus être déchiffré.
        deleteKey(slot, generation)
        val key = generateKeyPreferStrongBox(slot, generation)
        val payload = ByteBuffer.allocate(COUNTER_BYTES + secret.size).putLong(counter).put(secret).array()
        val cipher = Cipher.getInstance(TRANSFORMATION)
        cipher.init(Cipher.ENCRYPT_MODE, key)
        val sealed = cipher.iv + cipher.doFinal(payload)
        payload.fill(0)
        val target = blobFile(slot, generation)
        val tmp = File(context.filesDir, "${target.name}.tmp")
        tmp.writeBytes(sealed)
        if (!tmp.renameTo(target)) {
            tmp.delete()
            throw IllegalStateException("écriture impossible")
        }
    }

    private fun generateKeyPreferStrongBox(slot: Int, generation: Int): SecretKey {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            try {
                return generateKey(slot, generation, strongBox = true)
            } catch (_: StrongBoxUnavailableException) {
                // Pas de StrongBox sur ce téléphone : on retombe sur le TEE.
            }
        }
        return generateKey(slot, generation, strongBox = false)
    }

    private fun generateKey(slot: Int, generation: Int, strongBox: Boolean): SecretKey {
        val spec = KeyGenParameterSpec.Builder(
            alias(slot, generation),
            KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
        )
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setKeySize(256)
            .apply {
                if (strongBox && Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                    setIsStrongBoxBacked(true)
                }
            }
            .build()
        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, KEYSTORE)
        generator.init(spec)
        return generator.generateKey()
    }

    private companion object {
        const val KEYSTORE = "AndroidKeyStore"
        const val TRANSFORMATION = "AES/GCM/NoPadding"
        const val IV_BYTES = 12
        const val TAG_BITS = 128
        const val COUNTER_BYTES = 8
        const val SECRET_BYTES = 32
        const val LEGACY = 2
        val SLOTS = listOf(0, 1)
        val GENERATIONS = listOf(0, 1, LEGACY)
    }
}

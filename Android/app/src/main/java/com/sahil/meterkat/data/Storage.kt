package com.sahil.meterkat.data

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import androidx.room.*
import com.sahil.meterkat.model.*
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

@Entity(tableName = "clients")
data class ClientEntity(
    @PrimaryKey val id: String,
    val position: Int,
    val payload: String,
    val encryptedToken: String,
)

@Dao
interface ClientDao {
    @Query("SELECT * FROM clients ORDER BY position") suspend fun all(): List<ClientEntity>

    @Insert(onConflict = OnConflictStrategy.REPLACE) suspend fun save(client: ClientEntity)

    @Query("DELETE FROM clients WHERE id = :id") suspend fun delete(id: String)

    @Query("UPDATE clients SET position = :position WHERE id = :id")
    suspend fun position(id: String, position: Int)

    @Transaction
    suspend fun reorder(ids: List<String>) {
        ids.forEachIndexed { index, id -> position(id, index) }
    }
}

@Database(entities = [ClientEntity::class], version = 1, exportSchema = false)
abstract class MeterkatDatabase : RoomDatabase() {
    abstract fun clients(): ClientDao
}

class TokenVault {
    private val alias = "meterkat-pairing"

    private fun key(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(alias, null) as? SecretKey)?.let {
            return it
        }
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
            .apply {
                init(
                    KeyGenParameterSpec.Builder(
                            alias,
                            KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
                        )
                        .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                        .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                        .build()
                )
            }
            .generateKey()
    }

    fun encrypt(token: String): String {
        val cipher =
            Cipher.getInstance("AES/GCM/NoPadding").apply { init(Cipher.ENCRYPT_MODE, key()) }
        return Base64.encodeToString(
            cipher.iv + cipher.doFinal(token.toByteArray(Charsets.UTF_8)),
            Base64.NO_WRAP,
        )
    }

    fun decrypt(value: String): String {
        val bytes = Base64.decode(value, Base64.NO_WRAP)
        require(bytes.size > 12)
        return Cipher.getInstance("AES/GCM/NoPadding")
            .apply {
                init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, bytes.copyOfRange(0, 12)))
            }
            .doFinal(bytes.copyOfRange(12, bytes.size))
            .toString(Charsets.UTF_8)
    }
}

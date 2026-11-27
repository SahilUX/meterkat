package com.sahil.meterkat

import com.sahil.meterkat.model.PairingLinks
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

class PairingLinksTest {
    @Test
    fun parsesCurrentPairingLinkAndNormalizesAddresses() {
        val config =
            PairingLinks.parse(
                "meterkat://pair?local=http%3A%2F%2F127.0.0.1%3A8765%2F&remote=https%3A%2F%2Fexample.com&token=abc%2520xyz&name=Mac%20mini"
            )

        assertEquals("http://127.0.0.1:8765", config.localURL)
        assertEquals("https://example.com", config.remoteURL)
        assertEquals("abc%20xyz", config.token)
        assertEquals("Mac mini", config.name)
        assertEquals(2, config.routes.size)
    }

    @Test
    fun rejectsLegacyQueryAndInvalidSchemeOrShape() {
        assertThrows(IllegalArgumentException::class.java) {
            PairingLinks.parse("meterkat://pair?url=http%3A%2F%2Flocalhost&token=t")
        }
        assertThrows(IllegalArgumentException::class.java) {
            PairingLinks.parse("https://pair?local=http%3A%2F%2Flocalhost&token=t")
        }
        assertThrows(IllegalArgumentException::class.java) {
            PairingLinks.parse("meterkat://pair/extra?local=http%3A%2F%2Flocalhost&token=t")
        }
    }

    @Test
    fun rejectsDuplicateFieldsInvalidTokenAndInvalidAddresses() {
        val invalidLinks =
            listOf(
                "meterkat://pair?local=http%3A%2F%2Flocalhost&local=http%3A%2F%2Fother&token=t",
                "meterkat://pair?local=http%3A%2F%2Flocalhost&token=",
                "meterkat://pair?local=http%3A%2F%2Flocalhost&token=a%00b",
                "meterkat://pair?local=ftp%3A%2F%2Flocalhost&token=t",
                "meterkat://pair?local=http%3A%2F%2Flocalhost%2Fpath&token=t",
                "meterkat://pair?local=http%3A%2F%2Flocalhost%3A0&token=t",
                "meterkat://pair?token=t",
            )

        invalidLinks.forEach { link ->
            assertThrows(link, IllegalArgumentException::class.java) { PairingLinks.parse(link) }
        }
    }
}

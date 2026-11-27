package com.sahil.meterkat

import com.sahil.meterkat.data.CompanionHttpError
import com.sahil.meterkat.data.CompanionTransport
import com.sahil.meterkat.data.DeviceApiException
import com.sahil.meterkat.data.lastOwnerMessage
import com.sahil.meterkat.domain.*
import com.sahil.meterkat.model.*
import java.io.IOException
import java.time.Instant
import java.time.ZoneId
import kotlinx.coroutines.test.runTest
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.Assert.*
import org.junit.Test

class DevicesTest {
    private val now = Instant.parse("2026-10-25T12:00:00Z")

    private fun client(server: MockWebServer, role: String? = "owner") =
        ClientRecord(
            "client",
            "Box",
            listOf(CompanionRoute("local", server.url("/").toString().trimEnd('/'))),
            role = role,
        )

    private fun link(server: MockWebServer) =
        PairingConfig(
            localURL = server.url("/").toString().trimEnd('/'),
            pairingCode = "one-time",
            name = "devbox",
        )

    @Test
    fun relativeTimeCountsUpFromJustNow() {
        assertEquals("just now", relativeTime("2026-10-25T11:59:30Z", now))
        assertEquals("1 minute ago", relativeTime("2026-10-25T11:58:50Z", now))
        assertEquals("5 minutes ago", relativeTime("2026-10-25T11:55:00Z", now))
        assertEquals("1 hour ago", relativeTime("2026-10-25T10:30:00Z", now))
        assertEquals("3 days ago", relativeTime("2026-10-22T12:00:00Z", now))
        assertEquals("2 months ago", relativeTime("2026-08-20T12:00:00Z", now))
        assertEquals("just now", relativeTime("2026-10-25T12:05:00Z", now)) // clock skew
        assertNull(relativeTime(null, now))
        assertNull(relativeTime("not a date", now))
    }

    @Test
    fun neverUsedDeviceSaysNever() {
        assertEquals("never", lastActive(null, now))
        assertEquals("never", exactTime(null))
        assertEquals("2 hours ago", lastActive("2026-10-25T10:00:00Z", now))
    }

    @Test
    fun exactTimeIsLocalTime() {
        val text = exactTime("2026-10-25T02:30:00Z", ZoneId.of("Asia/Dubai"))
        assertTrue(text, text.contains("06:30"))
        assertTrue(text, text.contains("2026"))
    }

    @Test
    fun systemLabelNamesTheOsAndHeadless() {
        assertEquals("Linux, headless", systemLabel("linux", true))
        assertEquals("Linux", systemLabel("linux", false))
        assertEquals("macOS", systemLabel("macos", false))
        assertEquals("Freebsd", systemLabel("freebsd", null))
        assertNull(systemLabel(null, true))
    }

    @Test
    fun reachabilityDistinguishesUnreachableFromRejected() {
        val base = ClientRecord("c", "Box", emptyList())
        assertEquals(Reachability.Checking, reachability(base))
        val usage = UsageSnapshot("2026-10-25T12:00:00Z", providers = emptyList())
        assertEquals(Reachability.Reachable, reachability(base.copy(snapshot = usage)))
        assertEquals(Reachability.Unreachable, reachability(base.copy(snapshot = usage, error = "x")))
        assertEquals(
            Reachability.Rejected,
            reachability(base.copy(snapshot = usage, error = "x", authRejected = true)),
        )
    }

    @Test
    fun onlyOwnersGetTheDevicesScreen() {
        val base = ClientRecord("c", "Box", emptyList())
        assertTrue(base.copy(role = "owner").isOwner)
        assertFalse(base.copy(role = "viewer").isOwner)
        assertFalse(base.copy(role = "shared").isOwner)
        assertFalse(base.isOwner) // an older companion that cannot say
    }

    @Test
    fun oldClientRecordsStillDecode() {
        val saved =
            """{"id":"a","name":"Mac","routes":[{"kind":"local","baseURL":"http://10.0.0.2:47300"}],"error":null}"""
        val client = usageJson.decodeFromString<ClientRecord>(saved)
        assertNull(client.role)
        assertFalse(client.authRejected)
        assertFalse(client.isOwner)
    }

    @Test
    fun decodesTheDeviceList() {
        val json =
            """{"host":"devbox","companionVersion":"2.5.1","devices":[
              {"id":"66bee2ba","name":"BigMac","role":"owner","createdAt":"2026-10-25T02:25:00Z","lastUsedAt":"2026-10-25T02:31:00Z","hint":"wwbg","current":true},
              {"id":"a25eb504","name":"Home Assistant","role":"viewer","createdAt":"2026-10-25T02:09:00Z","lastUsedAt":null,"hint":"a4mg","current":false}],
              "sharedToken":{"label":"Shared token (older app versions)","lastUsedAt":"2026-10-25T02:30:00Z","current":false},
              "you":{"role":"owner","deviceId":"66bee2ba"},"extra":1}"""
        val list = usageJson.decodeFromString<DeviceList>(json)
        assertEquals(2, list.devices.size)
        assertTrue(list.devices[0].current)
        assertFalse(list.devices[1].current)
        assertNull(list.devices[1].lastUsedAt)
        assertEquals("never", lastActive(list.devices[1].lastUsedAt, now))
        assertEquals("Shared token (older app versions)", list.sharedToken?.label)
    }

    @Test
    fun routesOverlapIgnoresSlashAndCase() {
        val a = listOf(CompanionRoute("local", "http://192.168.1.40:47300"))
        val b = listOf(CompanionRoute("remote", "http://devbox.ts.net:47300"), CompanionRoute("local", "HTTP://192.168.1.40:47300/"))
        assertTrue(routesOverlap(a, b))
        assertFalse(routesOverlap(a, listOf(CompanionRoute("local", "http://192.168.1.41:47300"))))
    }

    @Test
    fun ownerLinkMatchesTheChosenComputerByAddressOrName() {
        val box = ClientRecord("c", "devbox", listOf(CompanionRoute("local", "http://192.168.1.40:47300")))
        assertTrue(isSameComputer(box, PairingConfig(localURL = "http://192.168.1.40:47300", pairingCode = "x")))
        assertTrue(isSameComputer(box, PairingConfig(remoteURL = "http://other:1", name = "DevBox", pairingCode = "x")))
        assertFalse(isSameComputer(box, PairingConfig(localURL = "http://192.168.1.42:47300", name = "mac", pairingCode = "x")))
    }

    @Test
    fun lastOwnerMessagePointsAtTheHostCli() {
        assertTrue(lastOwnerMessage(null).contains("meterkat devices revoke"))
        assertTrue(lastOwnerMessage("Keep one owner.").contains("meterkat devices revoke"))
        val full = "Revoke it with `meterkat devices revoke` on the host."
        assertEquals(full, lastOwnerMessage(full))
    }

    @Test
    fun viewerLinkRedeemsWithoutANameAndKeepsTheSharedToken() = runTest {
        MockWebServer().use { server ->
            server.enqueue(MockResponse().setBody("""{"token":"shared-secret"}"""))
            val result = CompanionTransport().redeemPairingCode(link(server), "Pixel")
            assertEquals("shared-secret", result.token)
            assertNull(result.deviceId)
            val request = server.takeRequest()
            assertEquals("/v1/pair", request.path)
            assertFalse(request.body.readUtf8().contains("name"))
            assertEquals(1, server.requestCount)
            assertFalse(result.toString().contains("shared-secret"))
        }
    }

    @Test
    fun ownerLinkRetriesWithTheDeviceNameOnNameRequired() = runTest {
        MockWebServer().use { server ->
            server.enqueue(MockResponse().setResponseCode(400).setBody("""{"error":"name_required","message":"x"}"""))
            server.enqueue(
                MockResponse()
                    .setBody("""{"token":"mkd_ab_secret","deviceId":"ab","role":"owner","name":"Pixel"}""")
            )
            val result = CompanionTransport().redeemPairingCode(link(server), " Pixel ")
            assertEquals("owner", result.role)
            assertEquals("ab", result.deviceId)
            assertFalse(server.takeRequest().body.readUtf8().contains("name"))
            val second = server.takeRequest().body.readUtf8()
            assertTrue(second, second.contains(""""name":"Pixel""""))
            assertTrue(second, second.contains(""""code":"one-time""""))
        }
    }

    @Test
    fun usedUpCodeAndRateLimitAreExplained() = runTest {
        MockWebServer().use { server ->
            server.enqueue(MockResponse().setResponseCode(401).setBody("""{"error":"pairing code expired or already used"}"""))
            try {
                CompanionTransport().redeemPairingCode(link(server), "Pixel")
                fail("Expected IOException")
            } catch (e: IOException) {
                assertTrue(e.message!!.contains("expired"))
            }
        }
        MockWebServer().use { server ->
            server.enqueue(MockResponse().setResponseCode(429).setHeader("Retry-After", "300").setBody("{}"))
            try {
                CompanionTransport().redeemPairingCode(link(server), "Pixel")
                fail("Expected DeviceApiException")
            } catch (e: DeviceApiException) {
                assertEquals(DeviceApiException.Kind.RateLimited, e.kind)
                assertTrue(e.message!!, e.message!!.contains("5 minutes"))
            }
        }
    }

    @Test
    fun meIsNullOnAnOlderCompanion() = runTest {
        MockWebServer().use { server ->
            server.enqueue(MockResponse().setResponseCode(404))
            assertNull(CompanionTransport().me(client(server), "t"))
        }
        MockWebServer().use { server ->
            server.enqueue(
                MockResponse()
                    .setBody("""{"role":"owner","kind":"device","deviceId":"ab","platform":"linux","headless":true,"companionVersion":"2.5.1"}""")
            )
            val me = CompanionTransport().me(client(server), "t")
            assertEquals("Linux, headless", systemLabel(me?.platform, me?.headless))
            assertEquals("Bearer t", server.takeRequest().getHeader("Authorization"))
        }
    }

    @Test
    fun revokeSendsDeleteAndMapsTheCompanionsAnswers() = runTest {
        MockWebServer().use { server ->
            server.enqueue(MockResponse().setBody("""{"revoked":{},"selfRevoked":false}"""))
            CompanionTransport().revoke(client(server), "t", "a25eb504")
            val request = server.takeRequest()
            assertEquals("DELETE", request.method)
            assertEquals("/v1/devices/a25eb504", request.path)
        }
        fun kindOf(code: Int, body: String, headers: Map<String, String> = emptyMap()): DeviceApiException.Kind? =
            runCatching {
                    kotlinx.coroutines.runBlocking {
                        MockWebServer().use { server ->
                            server.enqueue(
                                MockResponse().setResponseCode(code).setBody(body).apply {
                                    headers.forEach { (k, v) -> setHeader(k, v) }
                                }
                            )
                            CompanionTransport().revoke(client(server), "t", "x")
                        }
                    }
                }
                .exceptionOrNull()
                .let { (it as? DeviceApiException)?.kind }
        assertEquals(DeviceApiException.Kind.Gone, kindOf(404, "{}"))
        assertEquals(
            DeviceApiException.Kind.LastOwner,
            kindOf(409, """{"error":"last_owner","message":"This is the last owner device."}"""),
        )
        assertEquals(DeviceApiException.Kind.Rejected, kindOf(401, "{}"))
        assertEquals(DeviceApiException.Kind.Forbidden, kindOf(403, "{}"))
        assertEquals(DeviceApiException.Kind.RateLimited, kindOf(429, "{}", mapOf("Retry-After" to "42")))
    }

    @Test
    fun lastOwnerErrorTellsTheUserToUseTheHost() = runTest {
        MockWebServer().use { server ->
            server.enqueue(
                MockResponse().setResponseCode(409).setBody("""{"error":"last_owner","message":"This is the last owner."}""")
            )
            try {
                CompanionTransport().revoke(client(server), "t", "ab")
                fail("Expected DeviceApiException")
            } catch (e: DeviceApiException) {
                assertEquals(DeviceApiException.Kind.LastOwner, e.kind)
                assertTrue(e.message!!.contains("meterkat devices revoke"))
            }
        }
    }

    @Test
    fun unknownErrorKeepsTheStatusCode() = runTest {
        MockWebServer().use { server ->
            server.enqueue(MockResponse().setResponseCode(500))
            try {
                CompanionTransport().devices(client(server), "t")
                fail("Expected CompanionHttpError")
            } catch (e: CompanionHttpError) {
                assertEquals(500, e.code)
            }
        }
    }

    @Test
    fun devicesOnAnOlderCompanionSaysToUpdate() = runTest {
        MockWebServer().use { server ->
            server.enqueue(MockResponse().setResponseCode(404))
            try {
                CompanionTransport().devices(client(server), "t")
                fail("Expected DeviceApiException")
            } catch (e: DeviceApiException) {
                assertEquals(DeviceApiException.Kind.Unsupported, e.kind)
            }
        }
    }
}

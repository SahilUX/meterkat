package com.sahil.meterkat

import com.sahil.meterkat.data.CompanionHttpError
import com.sahil.meterkat.data.CompanionTransport
import com.sahil.meterkat.model.*
import java.io.IOException
import kotlinx.coroutines.async
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.test.runTest
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.SocketPolicy
import org.junit.Assert.*
import org.junit.Test

class CompanionTransportTest {
    private val snapshot =
        usageJson.encodeToString(UsageSnapshot("2026-01-01T00:00:00Z", providers = emptyList()))
    private val history = usageJson.encodeToString(UsageHistory("2026-01-01T00:00:00Z"))

    private fun client(server: MockWebServer, second: MockWebServer? = null) =
        ClientRecord(
            "client",
            "Client",
            listOfNotNull(
                CompanionRoute("local", server.url("/").toString().trimEnd('/')),
                second?.let { CompanionRoute("remote", it.url("/").toString().trimEnd('/')) },
            ),
        )

    @Test
    fun sendsBearerAuthAndFetchesOptionalHistory() = runTest {
        MockWebServer().use { server ->
            server.enqueue(MockResponse().setBody(snapshot))
            server.enqueue(MockResponse().setBody(history))
            val result = CompanionTransport().fetch(client(server), "secret")
            assertNotNull(result.snapshot)
            assertNotNull(result.history)
            assertEquals("Bearer secret", server.takeRequest().getHeader("Authorization"))
            assertEquals("/v1/history", server.takeRequest().path)
        }
    }

    @Test
    fun fallsBackToRemoteButDoesNotFallbackOnAuthRejection() = runTest {
        MockWebServer().use { local ->
            MockWebServer().use { remote ->
                local.enqueue(MockResponse().setBody("invalid JSON"))
                remote.enqueue(MockResponse().setBody(snapshot))
                remote.enqueue(MockResponse().setResponseCode(404))
                val result = CompanionTransport().fetch(client(local, remote), "token")
                assertEquals("remote", result.lastRoute?.kind)
                assertEquals(3, local.requestCount + remote.requestCount)
            }
        }
        MockWebServer().use { local ->
            MockWebServer().use { remote ->
                local.enqueue(MockResponse().setResponseCode(401))
                try {
                    CompanionTransport().fetch(client(local, remote), "token")
                    fail("Expected CompanionHttpError")
                } catch (error: CompanionHttpError) {
                    assertEquals(401, error.code)
                }
                assertEquals(1, local.requestCount)
                assertEquals(0, remote.requestCount)
            }
        }
    }

    @Test
    fun missingHistoryIsNonFatalAndCrossOriginRedirectIsNotFollowed() = runTest {
        MockWebServer().use { server ->
            server.enqueue(MockResponse().setBody(snapshot))
            server.enqueue(MockResponse().setResponseCode(404))
            val result = CompanionTransport().fetch(client(server), "token")
            assertNull(result.history)
        }
        MockWebServer().use { source ->
            MockWebServer().use { target ->
                source.enqueue(
                    MockResponse()
                        .setResponseCode(302)
                        .setHeader("Location", target.url("/v1/usage"))
                )
                try {
                    CompanionTransport().fetch(client(source), "token")
                    fail("Expected IOException")
                } catch (error: IOException) {
                    assertTrue(error is CompanionHttpError)
                }
                assertEquals(0, target.requestCount)
            }
        }
    }

    @Test
    fun doesNotFallbackOnHttp500() = runTest {
        MockWebServer().use { local ->
            MockWebServer().use { remote ->
                local.enqueue(MockResponse().setResponseCode(500))
                try {
                    CompanionTransport().fetch(client(local, remote), "token")
                    fail("Expected CompanionHttpError")
                } catch (error: CompanionHttpError) {
                    assertEquals(500, error.code)
                }
                assertEquals(1, local.requestCount)
                assertEquals(0, remote.requestCount)
            }
        }
    }

    @Test
    fun cancellationStopsWithoutTryingAnotherRoute() = runTest {
        MockWebServer().use { local ->
            MockWebServer().use { remote ->
                local.enqueue(MockResponse().setSocketPolicy(SocketPolicy.NO_RESPONSE))
                coroutineScope {
                    val request =
                        async(start = kotlinx.coroutines.CoroutineStart.UNDISPATCHED) {
                            CompanionTransport().fetch(client(local, remote), "token")
                        }
                    assertNotNull(
                        kotlinx.coroutines.withContext(kotlinx.coroutines.Dispatchers.IO) {
                            local.takeRequest(5, java.util.concurrent.TimeUnit.SECONDS)
                        }
                    )
                    request.cancelAndJoin()
                    assertTrue(request.isCancelled)
                }
                assertEquals(0, remote.requestCount)
            }
        }
    }
}

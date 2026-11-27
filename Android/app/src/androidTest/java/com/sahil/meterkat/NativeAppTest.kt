package com.sahil.meterkat

import android.graphics.Bitmap
import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.sahil.meterkat.data.MeterkatRepository
import com.sahil.meterkat.model.UsagePreferences
import java.net.URLEncoder
import java.time.Instant
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import kotlinx.coroutines.*
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import okhttp3.mockwebserver.SocketPolicy
import org.junit.*
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class NativeAppTest {
    @get:Rule val compose = createAndroidComposeRule<MainActivity>()
    private lateinit var repository: MeterkatRepository
    private lateinit var server: MockWebServer
    private val responseCode = AtomicInteger(200)

    @Before
    fun cleanAndStartCompanion() {
        repository = (compose.activity.application as MeterkatApplication).repository
        runBlocking {
            repository.initialize()
            repository.state.value.clients.toList().forEach { repository.remove(it.id) }
            repository.updatePreferences(UsagePreferences())
        }
        server = MockWebServer()
        val now = Instant.now()
        val usage =
            """{"generatedAt":"$now","host":"Test computer","providers":[{"id":"claude","name":"Claude","account":"alpha@example.test","plan":"pro","status":"ok","fetchedAt":"$now","windows":[{"id":"five_hour","label":"5-hour","kind":"session","percent":25,"resetsAt":"${now.plusSeconds(9000)}","windowSeconds":18000}]}]}"""
        server.dispatcher =
            object : Dispatcher() {
                override fun dispatch(request: RecordedRequest): MockResponse {
                    if (responseCode.get() == 0)
                        return MockResponse().setSocketPolicy(SocketPolicy.NO_RESPONSE)
                    if (responseCode.get() != 200)
                        return MockResponse().setResponseCode(responseCode.get())
                    return MockResponse()
                        .setHeader("Content-Type", "application/json")
                        .setBody(
                            if (request.path == "/v1/usage") usage
                            else """{"generatedAt":"$now","series":[]}"""
                        )
                }
            }
        server.start()
        compose.waitForIdle()
    }

    @After
    fun cleanUp() {
        runBlocking { repository.state.value.clients.toList().forEach { repository.remove(it.id) } }
        server.shutdown()
    }

    @Test
    fun onboardingRejectsBlankAndLegacyLinksWithoutPairing() {
        compose.onNodeWithText("Pair a computer").performClick()
        compose.onNodeWithText("Pair").performClick()
        compose
            .onNodeWithText("Use a meterkat://pair link from your companion.")
            .assertIsDisplayed()
        compose
            .onNodeWithText("Meterkat pairing link")
            .performTextReplacement(
                "meterkat://pair?url=http%3A%2F%2F127.0.0.1%3A1234&token=test-token"
            )
        compose.onNodeWithText("Pair").performClick()
        compose
            .onNodeWithText(
                "Generate a current Meterkat pairing link. Legacy links are unsupported."
            )
            .assertIsDisplayed()
        Assert.assertTrue(repository.state.value.clients.isEmpty())
        Assert.assertEquals(0, server.requestCount)
        compose.onNodeWithText("Cancel").performClick()
        compose.onNodeWithText("Provider credentials stay on your computer.").assertIsDisplayed()
    }

    @Test
    fun pairingNavigatesDisplayAndRestoresSavedPreferences() {
        pairThroughUi()
        compose.onNodeWithText("25% used").assertIsDisplayed()
        settings()
        compose.onNodeWithText("Display").performClick()
        compose.onNodeWithText("Remaining").performClick()
        compose.onNodeWithText("Graphs").performClick()
        compose.waitUntil(5000) {
            repository.state.value.preferences.remaining &&
                repository.state.value.preferences.graphs
        }
        compose.activityRule.scenario.recreate()
        compose.onNodeWithText("68% left").assertIsDisplayed()
        screenshot("qa-display.png")
        compose.onNodeWithText("Usage").performClick()
        compose.onNodeWithText("75% left").assertIsDisplayed()
        screenshot("qa-usage.png")
        // A new repository reads persisted Room and DataStore values, rather than the activity's
        // live state.
        val restored = MeterkatRepository(compose.activity.applicationContext)
        runBlocking { restored.initialize() }
        Assert.assertTrue(restored.state.value.preferences.remaining)
        Assert.assertTrue(restored.state.value.preferences.graphs)
        Assert.assertEquals("alpha@example.test", restored.state.value.providers.single().account)
    }

    @Test
    fun hiddenProviderDisappearsFromDashboardAndSurvivesRecreation() {
        pairThroughUi()
        settings()
        compose.onNodeWithText("Providers").performClick()
        compose.onNodeWithText("Claude").performClick()
        compose.onNodeWithText("Show Claude").performClick()
        compose.waitUntil(5000) {
            repository.state.value.preferences.providers["claude"]?.enabled == false
        }
        compose.onNodeWithText("Usage").performClick()
        compose
            .onNodeWithText("All providers are hidden. Enable one in Settings.")
            .assertIsDisplayed()
        compose.onNodeWithText("alpha@example.test").assertDoesNotExist()
        compose.activityRule.scenario.recreate()
        compose
            .onNodeWithText("All providers are hidden. Enable one in Settings.")
            .assertIsDisplayed()
    }

    @Test
    fun providersHaveTheirOwnScreenAndSystemBackReturnsThroughSettings() {
        settings()
        compose.onNodeWithText("Claude").assertDoesNotExist()
        compose.onNodeWithText("Providers").performClick()
        compose.onNodeWithText("Claude").assertIsDisplayed()
        compose.onNodeWithText("OpenAI").assertIsDisplayed()
        compose.onNodeWithText("Claude").performClick()
        compose.onNodeWithText("Show Claude").assertIsDisplayed()
        compose.runOnUiThread { compose.activity.onBackPressedDispatcher.onBackPressed() }
        compose.onNodeWithText("OpenAI").assertIsDisplayed()
        compose.onNodeWithText("Show Claude").assertDoesNotExist()
        compose.runOnUiThread { compose.activity.onBackPressedDispatcher.onBackPressed() }
        compose.onNodeWithText("Computers").assertIsDisplayed()
        compose.onNodeWithText("Claude").assertDoesNotExist()
    }

    @Test
    fun failedAndCancelledRefreshKeepCachedUsageAndClearLoading() {
        pairThroughUi()
        responseCode.set(503)
        compose.onNodeWithContentDescription("Refresh usage").performClick()
        compose.waitUntil(5000) {
            repository.state.value.clients.single().error != null && !repository.state.value.loading
        }
        compose.onNodeWithText("25% used").assertIsDisplayed()
        compose
            .onNodeWithText("Saved usage from Test computer.", substring = true)
            .assertIsDisplayed()
        Assert.assertTrue(repository.state.value.providers.single().sourceIsStale)
        while (server.takeRequest(20, TimeUnit.MILLISECONDS) != null) {
            /* drain earlier requests */
        }
        responseCode.set(0)
        runBlocking {
            val refresh = launch(Dispatchers.IO) { repository.refresh() }
            Assert.assertNotNull(server.takeRequest(5, TimeUnit.SECONDS))
            refresh.cancelAndJoin()
        }
        Assert.assertFalse(repository.state.value.loading)
        Assert.assertEquals(
            25.0,
            repository.state.value.providers.single().windows.single().percent,
            0.0,
        )
        compose.onNodeWithText("25% used").assertIsDisplayed()
    }

    private fun pairThroughUi() {
        val url = server.url("/").toString().trimEnd('/')
        val link =
            "meterkat://pair?local=${URLEncoder.encode(url, "UTF-8")}&token=test-token&name=Test%20computer"
        compose.onNodeWithText("Pair a computer").performClick()
        compose.onNodeWithText("Meterkat pairing link").performTextReplacement(link)
        compose.onNodeWithText("Pair").performClick()
        compose.waitUntil(10000) {
            repository.state.value.providers.isNotEmpty() && !repository.state.value.loading
        }
        compose.waitUntil(5000) {
            compose.onAllNodesWithText("Meterkat pairing link").fetchSemanticsNodes().isEmpty()
        }
        compose.waitUntil(5000) {
            compose.onAllNodesWithText("alpha@example.test").fetchSemanticsNodes().isNotEmpty()
        }
    }

    private fun settings() {
        compose.onNodeWithText("Settings").performClick()
    }

    private fun screenshot(name: String) {
        compose.waitForIdle()
        val bitmap = InstrumentationRegistry.getInstrumentation().uiAutomation.takeScreenshot()
        Assert.assertNotNull("The visible app screenshot must be available", bitmap)
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        java.io.File(context.cacheDir, name).outputStream().use {
            Assert.assertTrue(bitmap!!.compress(Bitmap.CompressFormat.PNG, 100, it))
        }
        bitmap!!.recycle()
    }
}

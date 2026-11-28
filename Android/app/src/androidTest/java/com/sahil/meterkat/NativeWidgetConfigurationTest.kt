package com.sahil.meterkat

import android.appwidget.AppWidgetHost
import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.content.Intent
import android.content.res.Configuration
import android.os.Bundle
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.junit4.createEmptyComposeRule
import androidx.compose.ui.test.onAllNodesWithText
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.core.view.ViewCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.test.core.app.ActivityScenario
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.sahil.meterkat.widget.SingleLimitReceiver
import com.sahil.meterkat.widget.WidgetConfigurationActivity
import java.net.URLEncoder
import java.time.Instant
import kotlinx.coroutines.runBlocking
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class NativeWidgetConfigurationTest {
    @get:Rule val compose = createEmptyComposeRule()

    @Test
    fun configurationTitleClearsSystemBarsAndStatusIconsMatchTheme() {
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val repository = (context.applicationContext as MeterkatApplication).repository
        runBlocking {
            repository.initialize()
            repository.state.value.clients.toList().forEach { repository.remove(it.id) }
        }
        val server = MockWebServer()
        server.start()
        val host = AppWidgetHost(context, 8128)
        val id = host.allocateAppWidgetId()
        try {
            val manager = AppWidgetManager.getInstance(context)
            assertTrue(
                "Grant appwidget bind permission before running this test",
                manager.bindAppWidgetIdIfAllowed(
                    id,
                    ComponentName(context, SingleLimitReceiver::class.java),
                    Bundle(),
                ),
            )
            val intent =
                Intent(context, WidgetConfigurationActivity::class.java)
                    .putExtra(AppWidgetManager.EXTRA_APPWIDGET_ID, id)
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            ActivityScenario.launch<WidgetConfigurationActivity>(intent).use { scenario ->
                compose.onNodeWithText("Configure Meterkat widget").assertIsDisplayed()
                compose
                    .onNodeWithText("Pair a client in Meterkat before adding this widget.")
                    .assertIsDisplayed()
                compose.onNodeWithText("Save widget").assertIsNotEnabled()
                compose.onNodeWithText("App setting").assertIsDisplayed()
                compose.onNodeWithText("Bars").assertIsDisplayed()
                compose.onNodeWithText("Graphs").assertIsDisplayed()
                val titleBounds =
                    compose
                        .onNodeWithText("Configure Meterkat widget")
                        .fetchSemanticsNode()
                        .boundsInWindow
                scenario.onActivity { activity ->
                    val insets = ViewCompat.getRootWindowInsets(activity.window.decorView)
                    assertNotNull(
                        "Window insets must be available for the visible configuration activity",
                        insets,
                    )
                    val safeTop =
                        insets!!
                            .getInsets(
                                WindowInsetsCompat.Type.systemBars() or
                                    WindowInsetsCompat.Type.displayCutout()
                            )
                            .top
                    assertTrue(
                        "Title top ${titleBounds.top}px overlaps safe inset ${safeTop}px",
                        titleBounds.top >= safeTop,
                    )
                    val dark =
                        activity.resources.configuration.uiMode and
                            Configuration.UI_MODE_NIGHT_MASK == Configuration.UI_MODE_NIGHT_YES
                    assertEquals(
                        "Status bar icon appearance must follow the visible app theme",
                        !dark,
                        WindowCompat.getInsetsController(activity.window, activity.window.decorView)
                            .isAppearanceLightStatusBars,
                    )
                }
                val now = Instant.now()
                server.enqueue(
                    MockResponse()
                        .setBody(
                            """{"generatedAt":"$now","host":"Test computer","providers":[{"id":"claude","name":"Claude","account":"config@example.test","status":"ok","fetchedAt":"$now","windows":[{"id":"five_hour","label":"5-hour","kind":"session","percent":25,"resetsAt":"${now.plusSeconds(9000)}","windowSeconds":18000}]}]}"""
                        )
                )
                server.enqueue(MockResponse().setBody("""{"generatedAt":"$now","series":[]}"""))
                runBlocking {
                    repository.pair(
                        "meterkat://pair?local=${URLEncoder.encode(server.url("/").toString(), "UTF-8")}&token=test-token"
                    )
                }
                compose.waitUntil(5000) {
                    compose
                        .onAllNodesWithText("Claude · config@example.test")
                        .fetchSemanticsNodes()
                        .isNotEmpty()
                }
                compose.onNodeWithText("Claude · config@example.test").performClick()
                compose.onNodeWithText("5-hour").performClick()
                compose.onNodeWithText("Save widget").assertIsEnabled()
            }
        } finally {
            runBlocking {
                repository.state.value.clients.toList().forEach { repository.remove(it.id) }
            }
            server.shutdown()
            host.deleteAppWidgetId(id)
            host.deleteHost()
            context
                .getSharedPreferences("widget_selections", 0)
                .edit()
                .remove("$id.account")
                .remove("$id.window")
                .remove("$id.style")
                .commit()
        }
    }
}

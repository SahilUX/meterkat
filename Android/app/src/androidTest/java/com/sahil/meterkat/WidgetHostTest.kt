package com.sahil.meterkat

import android.appwidget.AppWidgetHost
import android.appwidget.AppWidgetHostView
import android.appwidget.AppWidgetManager
import android.content.ComponentName
import android.os.Bundle
import android.os.SystemClock
import android.util.SizeF
import android.view.View
import android.view.ViewGroup
import android.widget.TextView
import android.widget.ImageView
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.sahil.meterkat.model.*
import com.sahil.meterkat.widget.*
import kotlinx.coroutines.runBlocking
import okhttp3.mockwebserver.*
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import java.net.URLEncoder
import java.time.Instant
import java.util.concurrent.atomic.AtomicBoolean

@RunWith(AndroidJUnit4::class)
class WidgetHostTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context get() = instrumentation.targetContext

    @Test fun threeResizableWidgetsRenderGraphsAndCachedRemainingUsage() {
        val repository = (context.applicationContext as MeterkatApplication).repository
        val server = MockWebServer()
        val failing = AtomicBoolean(false)
        val now = Instant.now()
        val snapshot = UsageSnapshot(now.toString(), providers = listOf(
            ProviderUsage("claude", "Claude", plan = "Pro", account = "alpha@example.test", status = "ok",
                fetchedAt = now.toString(), windows = listOf(
                    UsageWindow("five_hour", "session", "5-hour", 25.0, now.plusSeconds(9000).toString(), 18000),
                    UsageWindow("weekly", "weekly", "Weekly", 40.0, now.plusSeconds(345600).toString(), 604800)),
                apiCost = ApiCost(12.5, 32.0, weekTokens = 120000, monthTokens = 320000, priced = 4, unpriced = 0)),
            ProviderUsage("openai", "OpenAI", plan = "Plus", account = "beta@example.test", status = "ok",
                fetchedAt = now.toString(), windows = listOf(
                    UsageWindow("five_hour", "session", "5-hour", 35.0, now.plusSeconds(9000).toString(), 18000),
                    UsageWindow("weekly", "weekly", "Weekly", 50.0, now.plusSeconds(345600).toString(), 604800)))
        ))
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                if (failing.get()) return MockResponse().setResponseCode(503)
                val body = if (request.path == "/v1/usage")
                    usageJson.encodeToString(snapshot)
                else """{"generatedAt":"$now","series":[]}"""
                return MockResponse().setHeader("Content-Type", "application/json").setBody(body)
            }
        }
        server.start()
        val host = AppWidgetHost(context, 8127)
        val ids = mutableListOf<Int>()
        val selections = context.getSharedPreferences("widget_selections", 0)
        try {
            runBlocking {
                repository.initialize()
                repository.state.value.clients.toList().forEach { repository.remove(it.id) }
                repository.updatePreferences(UsagePreferences())
                val address = URLEncoder.encode(server.url("/").toString().trimEnd('/'), "UTF-8")
                repository.pair("meterkat://pair?local=$address&token=widget-test-token&name=Widget%20fixture")
            }
            instrumentation.runOnMainSync { host.startListening() }
            val manager = AppWidgetManager.getInstance(context)
            val receivers = listOf(SingleLimitReceiver::class.java, ProviderLimitsReceiver::class.java,
                AllLimitsReceiver::class.java)
            val views = mutableListOf<Pair<String, AppWidgetHostView>>()
            for (receiver in receivers) {
                val component = ComponentName(context, receiver)
                val id = host.allocateAppWidgetId()
                ids += id
                val options = sizeOptions(160, 160)
                assertTrue("Grant appwidget bind permission for ${context.packageName} before running this test",
                    manager.bindAppWidgetIdIfAllowed(id, component, options))
                assertTrue(selections.edit().putString("$id.account", "claude|alpha@example.test")
                    .putString("$id.window", "five_hour").commit())
                lateinit var view: AppWidgetHostView
                instrumentation.runOnMainSync {
                    view = host.createView(context, id, manager.getAppWidgetInfo(id))
                }
                views += receiver.simpleName to view
            }
            runBlocking { updateAllWidgets(context) }
            for ((name, view) in views) awaitRender(name, view, "25% used", 160, 160)
            for ((index, pair) in views.withIndex()) {
                instrumentation.runOnMainSync {
                    pair.second.updateAppWidgetOptions(sizeOptions(280, 320))
                }
                assertEquals(280, manager.getAppWidgetOptions(ids[index]).getInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH))
            }
            runBlocking { updateAllWidgets(context) }
            for ((name, view) in views) awaitRender(name, view, "25% used", 280, 320)
            runBlocking {
                repository.updatePreferences(repository.state.value.preferences.copy(graphs = true))
                updateAllWidgets(context)
            }
            for ((name, view) in views) awaitImage(name, view, "Usage graph")
            assertTrue(selections.edit().putString("${ids.first()}.style", "bars").commit())
            runBlocking { updateAllWidgets(context) }
            awaitImage(views.first().first, views.first().second, "Usage bar")
            assertTrue(selections.edit().remove("${ids.first()}.style").commit())
            runBlocking { updateAllWidgets(context) }
            awaitImage(views.first().first, views.first().second, "Usage graph")
            val dashboard = views.last().second
            instrumentation.runOnMainSync { dashboard.updateAppWidgetOptions(sizeOptions(360, 700)) }
            runBlocking { updateAllWidgets(context) }
            awaitRender(views.last().first, dashboard, "$12.50", 360, 700)
            assertTrue("Tall dashboard must include OpenAI rather than stopping after Claude", texts(dashboard).any { it.contains("OpenAI") })
            assertTrue("Tall dashboard must include the second limit", texts(dashboard).any { it.contains("Weekly") })
            assertTrue("Tall dashboard must include estimated API cost", texts(dashboard).contains("7d API estimate") && texts(dashboard).contains("$12.50"))
            assertTrue("Tall dashboard must include recorded tokens", texts(dashboard).contains("120.0k tokens"))
            failing.set(true)
            runBlocking {
                repository.refresh()
                repository.updatePreferences(repository.state.value.preferences.copy(remaining = true))
                updateAllWidgets(context)
            }
            assertTrue(repository.state.value.providers.all { it.sourceIsStale })
            for ((index, pair) in views.withIndex()) {
                val (name, view) = pair
                awaitRender(name, view, "75% left", if (index == views.lastIndex) 360 else 280,
                    if (index == views.lastIndex) 700 else 320)
                assertTrue("$name must label cached data stale", texts(view).any { it.contains("stale") && it.contains("refresh failed") })
                assertFalse("$name must replace used values", texts(view).contains("25% used"))
            }
        } finally {
            instrumentation.runOnMainSync { host.stopListening() }
            ids.forEach { host.deleteAppWidgetId(it) }
            host.deleteHost()
            selections.edit().apply { ids.forEach { remove("$it.account"); remove("$it.window"); remove("$it.style") } }.commit()
            runBlocking {
                repository.state.value.clients.toList().forEach { repository.remove(it.id) }
                repository.updatePreferences(UsagePreferences())
            }
            server.shutdown()
        }
    }

    private fun awaitImage(name: String, view: AppWidgetHostView, prefix: String) {
        val deadline = SystemClock.elapsedRealtime() + 20000
        var images = emptyList<String>()
        while (SystemClock.elapsedRealtime() < deadline) {
            instrumentation.runOnMainSync {
                fun read(node: View): List<String> = when (node) {
                    is ImageView -> if (node.drawable != null) listOf(node.contentDescription?.toString().orEmpty()) else emptyList()
                    is ViewGroup -> (0 until node.childCount).flatMap { read(node.getChildAt(it)) }
                    else -> emptyList()
                }
                images = read(view)
            }
            if (images.any { it.startsWith(prefix) }) return
            SystemClock.sleep(50)
        }
        fail("$name did not inflate a drawable ImageView described as $prefix. Images: $images")
    }

    private fun sizeOptions(width: Int, height: Int) = Bundle().apply {
        putInt(AppWidgetManager.OPTION_APPWIDGET_MIN_WIDTH, width)
        putInt(AppWidgetManager.OPTION_APPWIDGET_MAX_WIDTH, width)
        putInt(AppWidgetManager.OPTION_APPWIDGET_MIN_HEIGHT, height)
        putInt(AppWidgetManager.OPTION_APPWIDGET_MAX_HEIGHT, height)
        putParcelableArrayList(AppWidgetManager.OPTION_APPWIDGET_SIZES, arrayListOf(SizeF(width.toFloat(), height.toFloat())))
    }

    private fun awaitRender(name: String, view: AppWidgetHostView, expected: String, width: Int, height: Int) {
        val deadline = SystemClock.elapsedRealtime() + 20000
        var rendered = emptyList<String>()
        while (SystemClock.elapsedRealtime() < deadline) {
            instrumentation.runOnMainSync {
                val density = context.resources.displayMetrics.density
                val w = (width * density).toInt()
                val h = (height * density).toInt()
                view.measure(View.MeasureSpec.makeMeasureSpec(w, View.MeasureSpec.EXACTLY),
                    View.MeasureSpec.makeMeasureSpec(h, View.MeasureSpec.EXACTLY))
                view.layout(0, 0, w, h)
            }
            rendered = texts(view)
            if (expected in rendered) {
                assertFalse("$name RemoteViews error: $rendered", rendered.any { it.contains("Problem loading widget", true) })
                return
            }
            SystemClock.sleep(50)
        }
        fail("$name did not render $expected at ${width}x$height. Inflated text: $rendered")
    }

    private fun texts(view: View): List<String> {
        var result = emptyList<String>()
        instrumentation.runOnMainSync {
            fun read(node: View): List<String> = when (node) {
                is TextView -> listOf(node.text.toString())
                is ViewGroup -> (0 until node.childCount).flatMap { read(node.getChildAt(it)) }
                else -> emptyList()
            }
            result = read(view)
        }
        return result
    }
}

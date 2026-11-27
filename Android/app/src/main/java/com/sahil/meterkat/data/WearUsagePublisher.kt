package com.sahil.meterkat.data

import android.content.Context
import com.google.android.gms.wearable.PutDataMapRequest
import com.google.android.gms.wearable.Wearable
import com.sahil.meterkat.model.MeterkatState
import com.sahil.meterkat.model.usageJson
import kotlinx.coroutines.tasks.await

/** Sends the current cached summary to any paired Wear OS device. */
object WearUsagePublisher {
    suspend fun publish(context: Context, state: MeterkatState) {
        val payload = usageJson.encodeToString(state.providers)
        val request = PutDataMapRequest.create(PATH).apply {
            dataMap.putString("providers", payload)
            dataMap.putString("generatedAt", state.generatedAt.orEmpty())
            dataMap.putLong("updatedAt", System.currentTimeMillis())
        }.asPutDataRequest().setUrgent()
        runCatching { Wearable.getDataClient(context).putDataItem(request).await() }
    }

    const val PATH = "/meterkat/usage"
}

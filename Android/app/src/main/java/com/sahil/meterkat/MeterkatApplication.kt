package com.sahil.meterkat

import android.app.Application
import com.sahil.meterkat.background.RefreshWorker
import com.sahil.meterkat.data.MeterkatRepository
import kotlinx.coroutines.*

class MeterkatApplication : Application() {
    val repository by lazy { MeterkatRepository(this) }

    override fun onCreate() {
        super.onCreate()
        CoroutineScope(SupervisorJob() + Dispatchers.IO).launch {
            repository.initialize()
            if (repository.state.value.clients.isNotEmpty())
                RefreshWorker.schedule(this@MeterkatApplication)
        }
    }
}

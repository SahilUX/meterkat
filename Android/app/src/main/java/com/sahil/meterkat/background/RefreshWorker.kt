package com.sahil.meterkat.background

import android.content.Context
import androidx.work.BackoffPolicy
import androidx.work.Constraints
import androidx.work.CoroutineWorker
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.PeriodicWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import com.sahil.meterkat.MeterkatApplication
import java.util.concurrent.TimeUnit

class RefreshWorker(context: Context, params: WorkerParameters) : CoroutineWorker(context, params) {
    override suspend fun doWork(): Result =
        try {
            val repository = (applicationContext as MeterkatApplication).repository
            repository.refresh()
            Result.success()
        } catch (cancelled: kotlinx.coroutines.CancellationException) {
            throw cancelled
        } catch (_: Exception) {
            Result.retry()
        }

    companion object {
        private const val UNIQUE_NAME = "meterkat-refresh"
        private const val REFRESH_NOW_NAME = "meterkat-refresh-now"
        private const val BACKOFF_SECONDS = 30L

        private fun constraints() =
            Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build()

        fun schedule(context: Context) {
            val request =
                PeriodicWorkRequestBuilder<RefreshWorker>(15, TimeUnit.MINUTES)
                    .setConstraints(constraints())
                    .setBackoffCriteria(
                        BackoffPolicy.EXPONENTIAL,
                        BACKOFF_SECONDS,
                        TimeUnit.SECONDS,
                    )
                    .build()
            WorkManager.getInstance(context.applicationContext)
                .enqueueUniquePeriodicWork(
                    UNIQUE_NAME,
                    ExistingPeriodicWorkPolicy.KEEP,
                    request,
                )
        }

        fun refreshNow(context: Context) {
            val request =
                OneTimeWorkRequestBuilder<RefreshWorker>()
                    .setConstraints(constraints())
                    .setBackoffCriteria(
                        BackoffPolicy.EXPONENTIAL,
                        BACKOFF_SECONDS,
                        TimeUnit.SECONDS,
                    )
                    .build()
            WorkManager.getInstance(context.applicationContext)
                .enqueueUniqueWork(REFRESH_NOW_NAME, ExistingWorkPolicy.KEEP, request)
        }
    }
}

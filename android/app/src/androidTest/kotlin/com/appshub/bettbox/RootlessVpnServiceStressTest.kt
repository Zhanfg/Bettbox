package com.appshub.bettbox

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.net.VpnService
import android.os.IBinder
import android.os.ParcelFileDescriptor
import android.os.UserHandle
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import com.appshub.bettbox.models.AccessControl
import com.appshub.bettbox.models.AccessControlMode
import com.appshub.bettbox.models.VpnOptions
import com.appshub.bettbox.services.BettboxVpnService
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import java.io.FileInputStream
import java.net.DatagramSocket
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicReference

@RunWith(AndroidJUnit4::class)
class RootlessVpnServiceStressTest {
    private val instrumentation = InstrumentationRegistry.getInstrumentation()
    private val context: Context
        get() = ApplicationProvider.getApplicationContext()

    @Before
    fun authorizeVpnForTest() {
        shell(
            "appops set --user ${UserHandle.myUserId()} " +
                "${context.packageName} android:activate_vpn allow"
        )
        assertNull(
            "VpnService must be pre-authorized for unattended stability testing",
            VpnService.prepare(context)
        )
    }

    @After
    fun revokeVpnAuthorization() {
        shell(
            "appops set --user ${UserHandle.myUserId()} " +
                "${context.packageName} android:activate_vpn ignore"
        )
    }

    @Test
    fun establishCloseStormDoesNotLeakOrReject() = runBlocking {
        withBoundService { service ->
            repeat(250) { index ->
                val options = vpnOptions(
                    mtu = when (index % 3) {
                        0 -> 1280
                        1 -> 1500
                        else -> 9000
                    }
                )
                val fd = service.start(options)
                assertTrue("establish() rejected at iteration $index", fd > 0)
                ParcelFileDescriptor.adoptFd(fd).close()

                if (index % 25 == 0) {
                    assertNull(
                        "VPN authorization was lost during establish/close storm",
                        VpnService.prepare(context)
                    )
                }
            }
        }
    }

    @Test
    fun protectedSocketStormKeepsVpnEscapePathUsable() = runBlocking {
        withBoundService { service ->
            val fd = service.start(vpnOptions(mtu = 1500))
            assertTrue("initial establish() failed", fd > 0)
            val pfd = ParcelFileDescriptor.adoptFd(fd)
            try {
                repeat(2000) { index ->
                    DatagramSocket().use { socket ->
                        assertTrue(
                            "VpnService.protect() failed at socket $index",
                            service.protect(socket)
                        )
                    }
                }
            } finally {
                pfd.close()
            }
        }
    }

    @Test
    fun serviceRebindStormSurvivesRepeatedVpnLifecycle() = runBlocking {
        repeat(50) { index ->
            withBoundService { service ->
                val fd = service.start(vpnOptions(mtu = 1500))
                assertTrue("rebind establish() failed at cycle $index", fd > 0)
                ParcelFileDescriptor.adoptFd(fd).close()
            }
            Thread.sleep(25)
        }
    }

    private fun vpnOptions(mtu: Int) = VpnOptions(
        enable = true,
        port = 17890,
        accessControl = AccessControl(
            enable = false,
            mode = AccessControlMode.rejectSelected,
            acceptList = emptyList(),
            rejectList = emptyList(),
        ),
        allowBypass = true,
        systemProxy = false,
        bypassDomain = emptyList(),
        routeAddress = listOf(
            "198.18.0.0/15",
            "fd00::/8",
        ),
        routeMode = "config",
        ipv4Address = "198.18.0.1/32",
        ipv6Address = "fd00::1/128",
        dnsServerAddress = "",
        dozeSuspend = false,
        mtu = mtu,
    )

    private suspend fun withBoundService(
        block: suspend (BettboxVpnService) -> Unit,
    ) {
        val latch = CountDownLatch(1)
        val serviceRef = AtomicReference<BettboxVpnService?>()
        val errorRef = AtomicReference<Throwable?>()

        val connection = object : ServiceConnection {
            override fun onServiceConnected(name: ComponentName?, binder: IBinder?) {
                try {
                    serviceRef.set(
                        (binder as BettboxVpnService.LocalBinder).getService()
                    )
                } catch (error: Throwable) {
                    errorRef.set(error)
                } finally {
                    latch.countDown()
                }
            }

            override fun onServiceDisconnected(name: ComponentName?) {
                serviceRef.set(null)
            }
        }

        val intent = Intent(context, BettboxVpnService::class.java)
        assertTrue(
            "bindService() rejected",
            context.bindService(intent, connection, Context.BIND_AUTO_CREATE)
        )

        try {
            assertTrue(
                "BettboxVpnService bind timed out",
                latch.await(10, TimeUnit.SECONDS)
            )
            errorRef.get()?.let { throw it }
            val service = serviceRef.get()
                ?: throw AssertionError("BettboxVpnService binder returned no service")
            block(service)
        } finally {
            runCatching { context.unbindService(connection) }
        }
    }

    private fun shell(command: String): String {
        val descriptor = instrumentation.uiAutomation.executeShellCommand(command)
        return descriptor.use { pfd ->
            FileInputStream(pfd.fileDescriptor).bufferedReader().use { it.readText() }
        }
    }
}

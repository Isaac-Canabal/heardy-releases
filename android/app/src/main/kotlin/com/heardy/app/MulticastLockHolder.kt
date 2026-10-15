package com.heardy.app

import android.content.Context
import android.net.wifi.WifiManager

/**
 * Mantiene un MulticastLock solo mientras la pantalla de sincronizacion por
 * Wi-Fi esta abierta. Android descarta por defecto los paquetes multicast para
 * ahorrar bateria; sin el lock el descubrimiento de dispositivos cercanos no
 * recibe nada. Se libera siempre al cerrar la pantalla y al destruir la actividad.
 */
class MulticastLockHolder(private val context: Context) {
    private var lock: WifiManager.MulticastLock? = null

    @Synchronized
    fun acquire(): Boolean {
        if (lock?.isHeld == true) return true
        val wifi = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager
            ?: return false
        val created = wifi.createMulticastLock("heardy-lan-sync")
        created.setReferenceCounted(false)
        created.acquire()
        lock = created
        return true
    }

    @Synchronized
    fun release() {
        val held = lock
        lock = null
        if (held != null && held.isHeld) held.release()
    }
}

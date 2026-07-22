// ble_service.cpp — NimBLE GATT server for the HardFuzz campaign service.
//
// SCAFFOLD: the GATT table, the access callback (Control/Campaign dispatch), and the
// notify helpers are complete and wired to the engine callbacks. The NimBLE host
// bring-up + advertising at the bottom follows the stock ESP-IDF `bleprph` example and
// needs an on-hardware pass (it can't be built/tested in this repo). Marked TODO.
#include "ble_service.hpp"
#include "hf_config.hpp"
#include <cstring>
#include <string>
#include "host/ble_hs.h"
#include "host/util/util.h"
#include "services/gap/ble_svc_gap.h"
#include "services/gatt/ble_svc_gatt.h"
#include "nimble/nimble_port.h"
#include "nimble/nimble_port_freertos.h"

namespace hf {
namespace {

BleCallbacks   g_cb;
std::string    g_info = "HardFuzz v2";
std::string    g_campaign_buf;          // reassembled campaign JSON
uint16_t       g_conn = BLE_HS_CONN_HANDLE_NONE;
uint16_t       g_status_h = 0;          // attr handle of the Status characteristic value
uint16_t       g_result_h = 0;          // attr handle of the Result characteristic value

// Access callback for all characteristics; dispatched by (chr) argument below.
int access_cb(uint16_t conn, uint16_t attr, struct ble_gatt_access_ctxt* ctxt, void* arg) {
    const uintptr_t which = reinterpret_cast<uintptr_t>(arg);
    switch (ctxt->op) {
    case BLE_GATT_ACCESS_OP_READ_CHR:
        if (which == 0x10)   // Device Info
            return os_mbuf_append(ctxt->om, g_info.data(), g_info.size()) ? BLE_ATT_ERR_INSUFFICIENT_RES : 0;
        return 0;
    case BLE_GATT_ACCESS_OP_WRITE_CHR: {
        uint16_t n = OS_MBUF_PKTLEN(ctxt->om);
        static uint8_t buf[512];
        if (n > sizeof buf) n = sizeof buf;
        ble_hs_mbuf_to_flat(ctxt->om, buf, n, &n);
        if (which == 0x11) {                    // Campaign (chunked JSON)
            if (n == 1 && buf[0] == 0x00) {     // end-of-campaign marker
                if (g_cb.on_campaign) g_cb.on_campaign(g_campaign_buf);
                g_campaign_buf.clear();
            } else {
                g_campaign_buf.append(reinterpret_cast<char*>(buf), n);
            }
        } else if (which == 0x12 && n >= 1) {   // Control
            switch (buf[0]) {
            case CTL_START:  if (g_cb.on_start) g_cb.on_start(); break;
            case CTL_STOP:   if (g_cb.on_stop)  g_cb.on_stop();  break;
            case CTL_ARM:    if (g_cb.on_control_arm) g_cb.on_control_arm(buf + 1, n - 1); break;
            default: break;
            }
        }
        return 0;
    }
    default:
        return BLE_ATT_ERR_UNLIKELY;
    }
}

const struct ble_gatt_chr_def CHRS[] = {
    { .uuid = &(ble_uuid128_t)HF_CHR_INFO.u,     .access_cb = access_cb, .arg = (void*)0x10,
      .flags = BLE_GATT_CHR_F_READ },
    { .uuid = &(ble_uuid128_t)HF_CHR_CAMPAIGN.u, .access_cb = access_cb, .arg = (void*)0x11,
      .flags = BLE_GATT_CHR_F_WRITE },
    { .uuid = &(ble_uuid128_t)HF_CHR_CONTROL.u,  .access_cb = access_cb, .arg = (void*)0x12,
      .flags = BLE_GATT_CHR_F_WRITE },
    { .uuid = &(ble_uuid128_t)HF_CHR_STATUS.u,   .access_cb = access_cb, .arg = (void*)0x13,
      .flags = BLE_GATT_CHR_F_NOTIFY | BLE_GATT_CHR_F_READ, .val_handle = &g_status_h },
    { .uuid = &(ble_uuid128_t)HF_CHR_RESULT.u,   .access_cb = access_cb, .arg = (void*)0x14,
      .flags = BLE_GATT_CHR_F_NOTIFY, .val_handle = &g_result_h },
    { 0 }
};
const struct ble_gatt_svc_def SVCS[] = {
    { .type = BLE_GATT_SVC_TYPE_PRIMARY, .uuid = &(ble_uuid128_t)HF_SVC_UUID.u, .characteristics = CHRS },
    { 0 }
};

}  // namespace

void BleServer::set_info(const std::string& info) { g_info = info; }

void BleServer::notify_status(uint8_t state, uint16_t done, uint16_t total, const char* id) {
    if (g_conn == BLE_HS_CONN_HANDLE_NONE) return;
    uint8_t p[64];
    p[0] = state; p[1] = done & 0xff; p[2] = done >> 8; p[3] = total & 0xff; p[4] = total >> 8;
    size_t idn = id ? strnlen(id, 32) : 0;
    memcpy(p + 5, id, idn);
    ble_gatts_notify_custom(g_conn, g_status_h, ble_hs_mbuf_from_flat(p, 5 + idn));
}

void BleServer::notify_result(const hardfuzz::ScenarioResult& r) {
    if (g_conn == BLE_HS_CONN_HANDLE_NONE) return;
    // compact payload: [observed][pass] "id\0detail"
    std::string body = r.fault.id;
    body.push_back('\0');
    body += r.dut.detail;
    uint8_t p[160];
    p[0] = r.dut.fault_observed ? 1 : 0;
    p[1] = r.pass ? 1 : 0;
    size_t n = body.size() < sizeof(p) - 2 ? body.size() : sizeof(p) - 2;
    memcpy(p + 2, body.data(), n);
    ble_gatts_notify_custom(g_conn, g_result_h, ble_hs_mbuf_from_flat(p, 2 + n));
}

// ---- NimBLE host bring-up + advertising ----
// TODO(hardware): this mirrors the ESP-IDF `bleprph` example. Verify on an ESP32-S3:
// GAP event handler (store g_conn on CONNECT, clear + re-advertise on DISCONNECT),
// ble_svc_gap_device_name_set("HardFuzz"), start undirected connectable advertising with
// the service UUID, and nimble_port_freertos_init(host_task). Kept minimal here.
namespace {
int gap_event(struct ble_gap_event* ev, void* arg);

void advertise() {
    struct ble_gap_adv_params adv{};
    adv.conn_mode = BLE_GAP_CONN_MODE_UND;
    adv.disc_mode = BLE_GAP_DISC_MODE_GEN;
    uint8_t own;
    ble_hs_id_infer_auto(0, &own);
    ble_gap_adv_start(own, nullptr, BLE_HS_FOREVER, &adv, gap_event, nullptr);
}
int gap_event(struct ble_gap_event* ev, void*) {
    switch (ev->type) {
    case BLE_GAP_EVENT_CONNECT:
        g_conn = ev->connect.status == 0 ? ev->connect.conn_handle : BLE_HS_CONN_HANDLE_NONE;
        if (ev->connect.status != 0) advertise();
        break;
    case BLE_GAP_EVENT_DISCONNECT:
        g_conn = BLE_HS_CONN_HANDLE_NONE; advertise(); break;
    default: break;
    }
    return 0;
}
void on_sync() { advertise(); }
void host_task(void*) { nimble_port_run(); nimble_port_freertos_deinit(); }
}  // namespace

void BleServer::init(const BleCallbacks& cb) {
    g_cb = cb;
    nimble_port_init();
    ble_hs_cfg.sync_cb = on_sync;
    ble_svc_gap_init();
    ble_svc_gatt_init();
    ble_gatts_count_cfg(SVCS);
    ble_gatts_add_svcs(SVCS);
    ble_svc_gap_device_name_set("HardFuzz");
    nimble_port_freertos_init(host_task);
}

}  // namespace hf

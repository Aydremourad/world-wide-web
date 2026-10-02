/* QEMU test plugin, GPL-2.0-or-later. Never linked into the iOS app.
 * Count guest instructions rather than treating emulator time as ARM11 cycles.
 */
#include <stdio.h>
#include "qemu-plugin.h"
QEMU_PLUGIN_EXPORT int qemu_plugin_version=QEMU_PLUGIN_VERSION;
static uint64_t instructions;
static void translated(qemu_plugin_id_t id,struct qemu_plugin_tb *tb) {
    qemu_plugin_register_vcpu_tb_exec_inline(tb,QEMU_PLUGIN_INLINE_ADD_U64,
        &instructions,qemu_plugin_tb_n_insns(tb));
}
static void finished(qemu_plugin_id_t id,void *opaque) {
    fprintf(stderr,"ARM guest instructions: %" PRIu64 "\n",instructions);
}
QEMU_PLUGIN_EXPORT int qemu_plugin_install(qemu_plugin_id_t id,const qemu_info_t *info,int argc,char **argv) {
    qemu_plugin_register_vcpu_tb_trans_cb(id,translated);
    qemu_plugin_register_atexit_cb(id,finished,NULL); return 0;
}

#ifndef TX_USER_H
#define TX_USER_H

/* Cooperative bring-up: scheduling happens on explicit ThreadX service calls
 * (e.g. tx_thread_relinquish / suspend paths). */
#define TX_DISABLE_NOTIFY_CALLBACKS

#endif

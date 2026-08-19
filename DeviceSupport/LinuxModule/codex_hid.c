// SPDX-License-Identifier: GPL-2.0+
/*
 * Minimal Codex Micro USB HID function for the MK20/T113 Linux 5.4 kernel.
 *
 * The stock f_hid function in Linux 5.4 always allocates interrupt IN and
 * interrupt OUT endpoints.  The T113 UDC used by MK20 cannot bind that
 * endpoint pair.  This function exposes only interrupt IN and receives host
 * output reports through the HID SET_REPORT request on endpoint zero.
 *
 * The implementation is intentionally fixed to the Codex Micro report
 * descriptor: report ID 6 and 63 bytes of payload in each direction.
 */

#include <linux/cdev.h>
#include <linux/hid.h>
#include <linux/idr.h>
#include <linux/kernel.h>
#include <linux/list.h>
#include <linux/module.h>
#include <linux/mutex.h>
#include <linux/poll.h>
#include <linux/sched.h>
#include <linux/slab.h>
#include <linux/uaccess.h>
#include <linux/usb/composite.h>
#include <linux/wait.h>

#include "u_f.h"

#define CODEX_HID_MINORS 1
#define CODEX_REPORT_LENGTH 64
#define CODEX_RX_QUEUE_LIMIT 32

struct codex_report {
	struct list_head list;
	size_t length;
	size_t position;
	u8 data[];
};

struct codex_hid_opts {
	struct usb_function_instance func_inst;
	struct mutex lock;
	int refcnt;
	int minor;
};

struct codex_hid {
	struct usb_function func;
	struct usb_ep *in_ep;
	struct usb_request *in_req;

	spinlock_t write_lock;
	bool write_pending;
	wait_queue_head_t write_queue;

	spinlock_t read_lock;
	struct list_head reports;
	unsigned int report_count;
	wait_queue_head_t read_queue;

	u8 protocol;
	u8 idle;
	int minor;
	struct cdev cdev;
};

static int codex_major;
static int codex_minors;
static struct class *codex_class;
static DEFINE_IDA(codex_ida);
static DEFINE_MUTEX(codex_ida_lock);

static const u8 codex_report_desc[] = {
	0x06, 0x00, 0xff,       /* Usage Page (Vendor 0xff00) */
	0x09, 0x01,             /* Usage 1 */
	0xa1, 0x01,             /* Collection (Application) */
	0x85, 0x06,             /* Report ID 6 */
	0x15, 0x00,             /* Logical minimum 0 */
	0x26, 0xff, 0x00,       /* Logical maximum 255 */
	0x75, 0x08,             /* Report size 8 */
	0x95, 0x3f,             /* Report count 63 */
	0x09, 0x01,
	0x81, 0x02,             /* Input */
	0x95, 0x3f,
	0x09, 0x01,
	0x91, 0x02,             /* Output */
	0xc0,
};

static struct usb_interface_descriptor codex_interface_desc = {
	.bLength = sizeof(codex_interface_desc),
	.bDescriptorType = USB_DT_INTERFACE,
	.bAlternateSetting = 0,
	.bNumEndpoints = 1,
	.bInterfaceClass = USB_CLASS_HID,
	.bInterfaceSubClass = 0,
	.bInterfaceProtocol = 0,
};

static struct hid_descriptor codex_hid_desc = {
	.bLength = sizeof(codex_hid_desc),
	.bDescriptorType = HID_DT_HID,
	.bcdHID = cpu_to_le16(0x0101),
	.bCountryCode = 0,
	.bNumDescriptors = 1,
};

static struct usb_endpoint_descriptor codex_fs_in_desc = {
	.bLength = USB_DT_ENDPOINT_SIZE,
	.bDescriptorType = USB_DT_ENDPOINT,
	.bEndpointAddress = USB_DIR_IN,
	.bmAttributes = USB_ENDPOINT_XFER_INT,
	.wMaxPacketSize = cpu_to_le16(CODEX_REPORT_LENGTH),
	.bInterval = 10,
};

static struct usb_endpoint_descriptor codex_hs_in_desc = {
	.bLength = USB_DT_ENDPOINT_SIZE,
	.bDescriptorType = USB_DT_ENDPOINT,
	.bEndpointAddress = USB_DIR_IN,
	.bmAttributes = USB_ENDPOINT_XFER_INT,
	.wMaxPacketSize = cpu_to_le16(CODEX_REPORT_LENGTH),
	.bInterval = 4,
};

static struct usb_descriptor_header *codex_fs_descs[] = {
	(struct usb_descriptor_header *)&codex_interface_desc,
	(struct usb_descriptor_header *)&codex_hid_desc,
	(struct usb_descriptor_header *)&codex_fs_in_desc,
	NULL,
};

static struct usb_descriptor_header *codex_hs_descs[] = {
	(struct usb_descriptor_header *)&codex_interface_desc,
	(struct usb_descriptor_header *)&codex_hid_desc,
	(struct usb_descriptor_header *)&codex_hs_in_desc,
	NULL,
};

enum { CODEX_STRING_INTERFACE };

static struct usb_string codex_strings_defs[] = {
	[CODEX_STRING_INTERFACE].s = "Codex Micro RPC",
	{},
};

static struct usb_gadget_strings codex_string_table = {
	.language = 0x0409,
	.strings = codex_strings_defs,
};

static struct usb_gadget_strings *codex_strings[] = {
	&codex_string_table,
	NULL,
};

static inline struct codex_hid *func_to_codex(struct usb_function *func)
{
	return container_of(func, struct codex_hid, func);
}

static bool codex_read_ready(struct codex_hid *hid)
{
	return !list_empty(&hid->reports);
}

static bool codex_write_ready(struct codex_hid *hid)
{
	return !hid->write_pending && hid->in_req;
}

static ssize_t codex_read(struct file *file, char __user *buffer,
			 size_t count, loff_t *offset)
{
	struct codex_hid *hid = file->private_data;
	struct codex_report *report;
	unsigned long flags;
	size_t amount;

	if (!count)
		return 0;
	if (!access_ok(buffer, count))
		return -EFAULT;

	spin_lock_irqsave(&hid->read_lock, flags);
	while (!codex_read_ready(hid)) {
		spin_unlock_irqrestore(&hid->read_lock, flags);
		if (file->f_flags & O_NONBLOCK)
			return -EAGAIN;
		if (wait_event_interruptible(hid->read_queue,
					     codex_read_ready(hid)))
			return -ERESTARTSYS;
		spin_lock_irqsave(&hid->read_lock, flags);
	}

	report = list_first_entry(&hid->reports, struct codex_report, list);
	list_del(&report->list);
	hid->report_count--;
	spin_unlock_irqrestore(&hid->read_lock, flags);

	amount = min(count, report->length - report->position);
	if (copy_to_user(buffer, report->data + report->position, amount)) {
		spin_lock_irqsave(&hid->read_lock, flags);
		list_add(&report->list, &hid->reports);
		hid->report_count++;
		spin_unlock_irqrestore(&hid->read_lock, flags);
		return -EFAULT;
	}

	report->position += amount;
	if (report->position < report->length) {
		spin_lock_irqsave(&hid->read_lock, flags);
		list_add(&report->list, &hid->reports);
		hid->report_count++;
		spin_unlock_irqrestore(&hid->read_lock, flags);
		wake_up(&hid->read_queue);
	} else {
		kfree(report);
	}

	return amount;
}

static void codex_write_complete(struct usb_ep *ep, struct usb_request *req)
{
	struct codex_hid *hid = req->context;
	unsigned long flags;

	spin_lock_irqsave(&hid->write_lock, flags);
	hid->write_pending = false;
	spin_unlock_irqrestore(&hid->write_lock, flags);
	wake_up(&hid->write_queue);
}

static ssize_t codex_write(struct file *file, const char __user *buffer,
			  size_t count, loff_t *offset)
{
	struct codex_hid *hid = file->private_data;
	struct usb_request *req;
	unsigned long flags;
	int status;

	if (!count)
		return 0;
	if (!access_ok(buffer, count))
		return -EFAULT;

	count = min_t(size_t, count, CODEX_REPORT_LENGTH);

	spin_lock_irqsave(&hid->write_lock, flags);
	while (!codex_write_ready(hid)) {
		spin_unlock_irqrestore(&hid->write_lock, flags);
		if (file->f_flags & O_NONBLOCK)
			return -EAGAIN;
		if (wait_event_interruptible_exclusive(hid->write_queue,
						       codex_write_ready(hid)))
			return -ERESTARTSYS;
		spin_lock_irqsave(&hid->write_lock, flags);
	}

	hid->write_pending = true;
	req = hid->in_req;
	spin_unlock_irqrestore(&hid->write_lock, flags);

	if (copy_from_user(req->buf, buffer, count)) {
		status = -EFAULT;
		goto release_pending;
	}

	req->status = 0;
	req->zero = 0;
	req->length = count;
	req->complete = codex_write_complete;
	req->context = hid;
	status = usb_ep_queue(hid->in_ep, req, GFP_ATOMIC);
	if (!status)
		return count;

release_pending:
	spin_lock_irqsave(&hid->write_lock, flags);
	hid->write_pending = false;
	spin_unlock_irqrestore(&hid->write_lock, flags);
	wake_up(&hid->write_queue);
	return status;
}

static __poll_t codex_poll(struct file *file, poll_table *wait)
{
	struct codex_hid *hid = file->private_data;
	__poll_t result = 0;

	poll_wait(file, &hid->read_queue, wait);
	poll_wait(file, &hid->write_queue, wait);
	if (codex_read_ready(hid))
		result |= EPOLLIN | EPOLLRDNORM;
	if (codex_write_ready(hid))
		result |= EPOLLOUT | EPOLLWRNORM;
	return result;
}

static int codex_open(struct inode *inode, struct file *file)
{
	file->private_data = container_of(inode->i_cdev, struct codex_hid, cdev);
	return 0;
}

static int codex_release(struct inode *inode, struct file *file)
{
	file->private_data = NULL;
	return 0;
}

static const struct file_operations codex_fops = {
	.owner = THIS_MODULE,
	.open = codex_open,
	.release = codex_release,
	.read = codex_read,
	.write = codex_write,
	.poll = codex_poll,
	.llseek = noop_llseek,
};

static void codex_set_report_complete(struct usb_ep *ep,
				      struct usb_request *req)
{
	struct codex_hid *hid = req->context;
	struct codex_report *report;
	struct codex_report *oldest = NULL;
	unsigned long flags;

	if (req->status || !req->actual)
		return;

	report = kmalloc(sizeof(*report) + req->actual, GFP_ATOMIC);
	if (!report)
		return;
	report->length = req->actual;
	report->position = 0;
	memcpy(report->data, req->buf, req->actual);

	spin_lock_irqsave(&hid->read_lock, flags);
	if (hid->report_count >= CODEX_RX_QUEUE_LIMIT) {
		oldest = list_first_entry(&hid->reports,
					  struct codex_report, list);
		list_del(&oldest->list);
		hid->report_count--;
	}
	list_add_tail(&report->list, &hid->reports);
	hid->report_count++;
	spin_unlock_irqrestore(&hid->read_lock, flags);

	kfree(oldest);
	wake_up(&hid->read_queue);
}

static int codex_setup(struct usb_function *func,
			const struct usb_ctrlrequest *ctrl)
{
	struct codex_hid *hid = func_to_codex(func);
	struct usb_composite_dev *cdev = func->config->cdev;
	struct usb_request *req = cdev->req;
	u16 value = le16_to_cpu(ctrl->wValue);
	u16 length = le16_to_cpu(ctrl->wLength);
	int status;

	switch ((ctrl->bRequestType << 8) | ctrl->bRequest) {
	case ((USB_DIR_IN | USB_TYPE_CLASS | USB_RECIP_INTERFACE) << 8 |
	      HID_REQ_GET_REPORT):
		length = min_t(u16, length, CODEX_REPORT_LENGTH);
		memset(req->buf, 0, length);
		break;
	case ((USB_DIR_IN | USB_TYPE_CLASS | USB_RECIP_INTERFACE) << 8 |
	      HID_REQ_GET_PROTOCOL):
		length = min_t(u16, length, 1);
		((u8 *)req->buf)[0] = hid->protocol;
		break;
	case ((USB_DIR_IN | USB_TYPE_CLASS | USB_RECIP_INTERFACE) << 8 |
	      HID_REQ_GET_IDLE):
		length = min_t(u16, length, 1);
		((u8 *)req->buf)[0] = hid->idle;
		break;
	case ((USB_DIR_OUT | USB_TYPE_CLASS | USB_RECIP_INTERFACE) << 8 |
	      HID_REQ_SET_REPORT):
		if (!length || length > CODEX_REPORT_LENGTH)
			return -EOPNOTSUPP;
		req->complete = codex_set_report_complete;
		req->context = hid;
		break;
	case ((USB_DIR_OUT | USB_TYPE_CLASS | USB_RECIP_INTERFACE) << 8 |
	      HID_REQ_SET_PROTOCOL):
		if (value > HID_REPORT_PROTOCOL)
			return -EOPNOTSUPP;
		hid->protocol = value;
		length = 0;
		break;
	case ((USB_DIR_OUT | USB_TYPE_CLASS | USB_RECIP_INTERFACE) << 8 |
	      HID_REQ_SET_IDLE):
		hid->idle = value >> 8;
		length = 0;
		break;
	case ((USB_DIR_IN | USB_TYPE_STANDARD | USB_RECIP_INTERFACE) << 8 |
	      USB_REQ_GET_DESCRIPTOR):
		switch (value >> 8) {
		case HID_DT_HID: {
			struct hid_descriptor copy = codex_hid_desc;
			copy.desc[0].bDescriptorType = HID_DT_REPORT;
			copy.desc[0].wDescriptorLength =
				cpu_to_le16(sizeof(codex_report_desc));
			length = min_t(u16, length, copy.bLength);
			memcpy(req->buf, &copy, length);
			break;
		}
		case HID_DT_REPORT:
			length = min_t(u16, length, sizeof(codex_report_desc));
			memcpy(req->buf, codex_report_desc, length);
			break;
		default:
			return -EOPNOTSUPP;
		}
		break;
	default:
		return -EOPNOTSUPP;
	}

	req->zero = 0;
	req->length = length;
	status = usb_ep_queue(cdev->gadget->ep0, req, GFP_ATOMIC);
	if (status < 0)
		ERROR(cdev, "codexhid: ep0 queue failed: %d\n", status);
	return status;
}

static void codex_clear_reports(struct codex_hid *hid)
{
	struct codex_report *report;
	struct codex_report *next;
	unsigned long flags;

	spin_lock_irqsave(&hid->read_lock, flags);
	list_for_each_entry_safe(report, next, &hid->reports, list) {
		list_del(&report->list);
		kfree(report);
	}
	hid->report_count = 0;
	spin_unlock_irqrestore(&hid->read_lock, flags);
}

static void codex_disable(struct usb_function *func)
{
	struct codex_hid *hid = func_to_codex(func);
	unsigned long flags;

	if (hid->in_ep)
		usb_ep_disable(hid->in_ep);
	codex_clear_reports(hid);

	spin_lock_irqsave(&hid->write_lock, flags);
	if (hid->in_req && !hid->write_pending)
		free_ep_req(hid->in_ep, hid->in_req);
	hid->in_req = NULL;
	hid->write_pending = true;
	spin_unlock_irqrestore(&hid->write_lock, flags);
	wake_up(&hid->write_queue);
}

static int codex_set_alt(struct usb_function *func, unsigned intf,
			 unsigned alt)
{
	struct codex_hid *hid = func_to_codex(func);
	struct usb_composite_dev *cdev = func->config->cdev;
	struct usb_request *req;
	unsigned long flags;
	int status;

	usb_ep_disable(hid->in_ep);
	status = config_ep_by_speed(cdev->gadget, func, hid->in_ep);
	if (status)
		return status;
	status = usb_ep_enable(hid->in_ep);
	if (status)
		return status;
	hid->in_ep->driver_data = hid;

	req = alloc_ep_req(hid->in_ep, CODEX_REPORT_LENGTH);
	if (!req) {
		usb_ep_disable(hid->in_ep);
		return -ENOMEM;
	}

	spin_lock_irqsave(&hid->write_lock, flags);
	hid->in_req = req;
	hid->write_pending = false;
	spin_unlock_irqrestore(&hid->write_lock, flags);
	wake_up(&hid->write_queue);
	return 0;
}

static int codex_bind(struct usb_configuration *config,
			struct usb_function *func)
{
	struct codex_hid *hid = func_to_codex(func);
	struct usb_string *strings;
	struct usb_ep *ep;
	struct device *device;
	dev_t dev;
	int status;

	strings = usb_gstrings_attach(config->cdev, codex_strings,
				      ARRAY_SIZE(codex_strings_defs));
	if (IS_ERR(strings))
		return PTR_ERR(strings);
	codex_interface_desc.iInterface = strings[CODEX_STRING_INTERFACE].id;

	status = usb_interface_id(config, func);
	if (status < 0)
		return status;
	codex_interface_desc.bInterfaceNumber = status;

	ep = usb_ep_autoconfig(config->cdev->gadget, &codex_fs_in_desc);
	if (!ep)
		return -ENODEV;
	hid->in_ep = ep;
	codex_hs_in_desc.bEndpointAddress = codex_fs_in_desc.bEndpointAddress;
	codex_hid_desc.desc[0].bDescriptorType = HID_DT_REPORT;
	codex_hid_desc.desc[0].wDescriptorLength =
		cpu_to_le16(sizeof(codex_report_desc));

	status = usb_assign_descriptors(func, codex_fs_descs,
					codex_hs_descs, NULL, NULL);
	if (status)
		return status;

	spin_lock_init(&hid->write_lock);
	hid->write_pending = true;
	init_waitqueue_head(&hid->write_queue);
	spin_lock_init(&hid->read_lock);
	INIT_LIST_HEAD(&hid->reports);
	init_waitqueue_head(&hid->read_queue);
	hid->protocol = HID_REPORT_PROTOCOL;
	hid->idle = 1;

	cdev_init(&hid->cdev, &codex_fops);
	dev = MKDEV(codex_major, hid->minor);
	status = cdev_add(&hid->cdev, dev, 1);
	if (status)
		goto free_descs;
	device = device_create(codex_class, NULL, dev, NULL,
			       "codexhidg%d", hid->minor);
	if (IS_ERR(device)) {
		status = PTR_ERR(device);
		cdev_del(&hid->cdev);
		goto free_descs;
	}

	INFO(config->cdev, "codexhid: bound with one interrupt IN endpoint\n");
	return 0;

free_descs:
	usb_free_all_descriptors(func);
	return status;
}

static void codex_unbind(struct usb_configuration *config,
			 struct usb_function *func)
{
	struct codex_hid *hid = func_to_codex(func);

	device_destroy(codex_class, MKDEV(codex_major, hid->minor));
	cdev_del(&hid->cdev);
	codex_clear_reports(hid);
	usb_free_all_descriptors(func);
}

static inline struct codex_hid_opts *item_to_opts(struct config_item *item)
{
	return container_of(to_config_group(item), struct codex_hid_opts,
			    func_inst.group);
}

static void codex_attr_release(struct config_item *item)
{
	struct codex_hid_opts *opts = item_to_opts(item);
	usb_put_function_instance(&opts->func_inst);
}

static struct configfs_item_operations codex_item_ops = {
	.release = codex_attr_release,
};

static const struct config_item_type codex_func_type = {
	.ct_item_ops = &codex_item_ops,
	.ct_owner = THIS_MODULE,
};

static int codex_setup_chrdev(void)
{
	dev_t dev;
	int status;

	codex_class = class_create(THIS_MODULE, "codexhidg");
	if (IS_ERR(codex_class)) {
		status = PTR_ERR(codex_class);
		codex_class = NULL;
		return status;
	}
	status = alloc_chrdev_region(&dev, 0, CODEX_HID_MINORS, "codexhidg");
	if (status) {
		class_destroy(codex_class);
		codex_class = NULL;
		return status;
	}
	codex_major = MAJOR(dev);
	codex_minors = CODEX_HID_MINORS;
	return 0;
}

static void codex_cleanup_chrdev(void)
{
	if (codex_major) {
		unregister_chrdev_region(MKDEV(codex_major, 0), codex_minors);
		codex_major = 0;
		codex_minors = 0;
	}
	if (codex_class) {
		class_destroy(codex_class);
		codex_class = NULL;
	}
}

static void codex_free_inst(struct usb_function_instance *instance)
{
	struct codex_hid_opts *opts = container_of(instance,
						  struct codex_hid_opts,
						  func_inst);

	mutex_lock(&codex_ida_lock);
	ida_simple_remove(&codex_ida, opts->minor);
	if (ida_is_empty(&codex_ida))
		codex_cleanup_chrdev();
	mutex_unlock(&codex_ida_lock);
	kfree(opts);
}

static struct usb_function_instance *codex_alloc_inst(void)
{
	struct codex_hid_opts *opts;
	int status;

	opts = kzalloc(sizeof(*opts), GFP_KERNEL);
	if (!opts)
		return ERR_PTR(-ENOMEM);
	mutex_init(&opts->lock);
	opts->func_inst.free_func_inst = codex_free_inst;

	mutex_lock(&codex_ida_lock);
	if (ida_is_empty(&codex_ida)) {
		status = codex_setup_chrdev();
		if (status)
			goto fail;
	}
	opts->minor = ida_simple_get(&codex_ida, 0, 0, GFP_KERNEL);
	if (opts->minor < 0 || opts->minor >= CODEX_HID_MINORS) {
		status = opts->minor < 0 ? opts->minor : -ENODEV;
		if (opts->minor >= 0)
			ida_simple_remove(&codex_ida, opts->minor);
		if (ida_is_empty(&codex_ida))
			codex_cleanup_chrdev();
		goto fail;
	}
	config_group_init_type_name(&opts->func_inst.group, "",
				    &codex_func_type);
	mutex_unlock(&codex_ida_lock);
	return &opts->func_inst;

fail:
	mutex_unlock(&codex_ida_lock);
	kfree(opts);
	return ERR_PTR(status);
}

static void codex_free_func(struct usb_function *func)
{
	struct codex_hid *hid = func_to_codex(func);
	struct codex_hid_opts *opts = container_of(func->fi,
						  struct codex_hid_opts,
						  func_inst);

	kfree(hid);
	mutex_lock(&opts->lock);
	opts->refcnt--;
	mutex_unlock(&opts->lock);
}

static struct usb_function *codex_alloc_func(
		struct usb_function_instance *instance)
{
	struct codex_hid_opts *opts = container_of(instance,
						  struct codex_hid_opts,
						  func_inst);
	struct codex_hid *hid;

	hid = kzalloc(sizeof(*hid), GFP_KERNEL);
	if (!hid)
		return ERR_PTR(-ENOMEM);

	mutex_lock(&opts->lock);
	opts->refcnt++;
	hid->minor = opts->minor;
	mutex_unlock(&opts->lock);

	hid->func.name = "codexhid";
	hid->func.bind = codex_bind;
	hid->func.unbind = codex_unbind;
	hid->func.set_alt = codex_set_alt;
	hid->func.disable = codex_disable;
	hid->func.setup = codex_setup;
	hid->func.free_func = codex_free_func;
	return &hid->func;
}

DECLARE_USB_FUNCTION_INIT(codexhid, codex_alloc_inst, codex_alloc_func);

MODULE_DESCRIPTION("MK20 single-endpoint Codex Micro HID function");
MODULE_AUTHOR("CodexPetDeck");
MODULE_LICENSE("GPL");

import { readFileSync, readdirSync } from 'node:fs'
import { resolve } from 'node:path'
import { pathToFileURL } from 'node:url'

const modulePath = process.env.MK20_CONTROL_MODULE ?? process.argv[2]
if (!modulePath) {
  throw new Error(
    '请通过 MK20_CONTROL_MODULE 或第一个命令行参数提供 MK20Device 模块路径',
  )
}

const { MK20Device } = await import(pathToFileURL(resolve(modulePath)).href)

const source = new URL('../DeviceSupport/mk20-recover-lunch.sh', import.meta.url)
const payload = readFileSync(source)
let lastError = new Error('未找到 MK20 串口')

for (let attempt = 1; attempt <= 40; attempt += 1) {
  const entry = readdirSync('/dev').find((value) =>
    /^cu\.usbmodem(?:\d+|MK20_CODEX)/i.test(value),
  )
  const path = entry ? `/dev/${entry}` : undefined
  if (!path) {
    await new Promise((resolve) => setTimeout(resolve, 500))
    continue
  }

  const device = new MK20Device(path)
  device.on('error', (error) => { lastError = error })
  try {
    await device.open()
    await new Promise((resolve) => setTimeout(resolve, 150))
    const ack = await device.uploadFile('/mnt/SDCARD/lunch.sh', payload, {
      ackTimeoutMs: 2_500,
    })
    console.log(JSON.stringify({ path, bytes: payload.length, ack }))
    device.close()
    process.exit(0)
  } catch (error) {
    lastError = error
    if (device.port?.isOpen) device.close()
    await new Promise((resolve) => setTimeout(resolve, 250))
  }
}

throw lastError

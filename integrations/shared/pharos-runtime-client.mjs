import net from 'node:net'
import os from 'node:os'
import path from 'node:path'

const defaultSocket = path.join(
  os.homedir(),
  'Library/Application Support/Pharos/Runtime/agent-runtime.sock',
)

export class PharosRuntimeClient {
  constructor(socketPath = process.env.PHAROS_RUNTIME_SOCKET || process.env.PHAROS_AGENT_RUNTIME_SOCKET || defaultSocket) {
    this.socketPath = socketPath
    this.nextID = 1
  }

  call(method, params = {}) {
    const id = this.nextID++
    return new Promise((resolve, reject) => {
      const socket = net.createConnection(this.socketPath)
      let buffer = ''
      const timeout = setTimeout(() => {
        socket.destroy()
        reject(new Error(`Pharos Runtime timed out: ${method}`))
      }, 10_000)
      const finish = (error, value) => {
        clearTimeout(timeout)
        socket.destroy()
        error ? reject(error) : resolve(value)
      }
      socket.setEncoding('utf8')
      socket.on('connect', () => {
        socket.write(`${JSON.stringify({ jsonrpc: '2.0', id, method, params })}\n`)
      })
      socket.on('data', chunk => {
        buffer += chunk
        const newline = buffer.indexOf('\n')
        if (newline < 0) return
        try {
          const response = JSON.parse(buffer.slice(0, newline))
          if (response.error) finish(new Error(response.error.message || method))
          else finish(null, response.result)
        } catch (error) {
          finish(error)
        }
      })
      socket.on('error', error => finish(error))
    })
  }

  registerDriver({ driverID, kind, version, capabilities = [] }) {
    return this.call('driver.register', {
      driverID,
      kind,
      version,
      capabilities,
      processID: process.pid,
    })
  }

  heartbeat(driverID) {
    return this.call('driver.heartbeat', { driverID })
  }

  registerConversation({ driverID, vendorSessionID, memberID, kind, title, projectPath }) {
    return this.call('conversation.register', {
      driverID,
      vendorSessionID,
      memberID,
      kind,
      title,
      projectPath,
      ownership: 'attached',
    })
  }

  updateConversationState(params) {
    return this.call('conversation.state', params)
  }

  poll(conversationID) {
    return this.call('delivery.poll', { conversationID })
  }

  acknowledge(deliveryID, state, detail) {
    return this.call('delivery.ack', { deliveryID, state, detail })
  }
}

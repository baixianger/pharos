import net from 'node:net'
import os from 'node:os'
import path from 'node:path'

const defaultSocketPath = path.join(
  os.homedir(),
  'Library',
  'Application Support',
  'Pharos',
  'Runtime',
  'agent-runtime.sock',
)

export class PharosRuntimeClient {
  constructor({
    socketPath = process.env.PHAROS_RUNTIME_SOCKET || defaultSocketPath,
    timeoutMS = 5_000,
  } = {}) {
    this.socketPath = socketPath
    this.timeoutMS = timeoutMS
    this.nextRequestId = 1
  }

  call(method, params = {}) {
    const request = {
      jsonrpc: '2.0',
      id: this.nextRequestId++,
      method,
      params,
    }

    return new Promise((resolve, reject) => {
      const socket = net.createConnection(this.socketPath)
      let response = ''

      socket.setEncoding('utf8')
      socket.setTimeout(this.timeoutMS, () => {
        socket.destroy(new Error(`Pharos Runtime RPC timed out: ${method}`))
      })
      socket.on('connect', () => socket.end(`${JSON.stringify(request)}\n`))
      socket.on('data', (chunk) => { response += chunk })
      socket.on('error', reject)
      socket.on('end', () => {
        try {
          const message = JSON.parse(response.trim())
          if (message.error) reject(new Error(message.error.message || JSON.stringify(message.error)))
          else resolve(message.result)
        } catch (error) {
          reject(error)
        }
      })
    })
  }

  registerDriver(params) { return this.call('driver.register', params) }
  heartbeat(driverID) { return this.call('driver.heartbeat', { driverID }) }
  registerConversation(params) { return this.call('conversation.register', params) }
  updateConversationState(params) { return this.call('conversation.state', params) }
  poll(conversationID) { return this.call('delivery.poll', { conversationID }) }
  acknowledge(deliveryID, state, detail) {
    return this.call('delivery.ack', { deliveryID, state, detail })
  }
}

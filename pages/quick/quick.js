// pages/quick/quick.js
const app = getApp();
const STORAGE_KEY = 'quick_actions';

Page({
  data: {
    actions: [],          // [{id, name, deviceMac, serviceUuid, charUuid, writeType, value, color}]
    connectedDevice: null,

    // 编辑面板状态
    showEditor: false,
    isEditMode: false,    // true=编辑已有, false=新增
    editingId: null,

    // 表单字段
    form: {
      name: '',
      deviceName: '',
      deviceMac: '',
      serviceUuid: '',
      charUuid: '',
      writeType: 'hex',
      value: '',
      color: 'blue',
    },

    colorOptions: [
      { key: 'blue',   label: '蓝',  bg: '#e8f0fe', border: '#1976d2', text: '#1565c0' },
      { key: 'green',  label: '绿',  bg: '#e8f5e9', border: '#388e3c', text: '#2e7d32' },
      { key: 'orange', label: '橙',  bg: '#fff3e0', border: '#f57c00', text: '#e65100' },
      { key: 'red',    label: '红',  bg: '#ffebee', border: '#e53935', text: '#c62828' },
      { key: 'purple', label: '紫',  bg: '#f3e5f5', border: '#8e24aa', text: '#7b1fa2' },
      { key: 'teal',   label: '青',  bg: '#e0f2f1', border: '#00897b', text: '#00695c' },
    ],

    // 执行状态：{ [id]: 'idle'|'running'|'ok'|'err' }
    execState: {},
    // 执行提示文字：{ [id]: string }
    execHint: {},
  },

onLoad() {
  this._loadActions();
  this._currentSession = null; // 当前执行会话令牌
  // 全局只注册一次连接状态监听
  wx.onBLEConnectionStateChange(res => {
    if (!res.connected) {
      // 断开后如果是当前连接设备，清空全局状态
      const cur = app.globalData.connectedDevice;
      if (cur && cur.deviceId === res.deviceId) {
        app.globalData.connectedDevice = null;
        app.globalData.services = [];
        this.setData({ connectedDevice: null });
        app.addLog('info', '', `[快捷] 设备断开: ${cur.name || res.deviceId}`, 'info');
      }
    }
  });
},

onShow() {
const d = app.globalData.connectedDevice;
// 直接同步显示，不发起异步查询（避免干扰正在进行的蓝牙扫描流程）
this.setData({ connectedDevice: d || null });
// 检查是否有来自特征值页的预填数据
const prefill = app.globalData._quickPrefill;
if (prefill) {
app.globalData._quickPrefill = null; // 消费后清除，防止重复触发
const name = prefill.deviceName
  ? `${prefill.deviceName} 快捷`
  : prefill.charUuid.slice(-8).toUpperCase();
this.setData({
showEditor: true,
isEditMode: false,
editingId: null,
form: {
name,
deviceName:  prefill.deviceName || '',
deviceMac:   prefill.deviceMac || '',
serviceUuid: prefill.serviceUuid || '',
charUuid:    prefill.charUuid || '',
writeType:   prefill.writeType === 'text' ? 'text' : 'hex',
value:       prefill.value || '',
color: 'blue',
},
});
}
},

  // ==================== 数据持久化 ====================
  _loadActions() {
    try {
      const raw = wx.getStorageSync(STORAGE_KEY);
      this.setData({ actions: Array.isArray(raw) ? raw : [] });
    } catch (e) {
      this.setData({ actions: [] });
    }
  },

  _saveActions() {
    try {
      wx.setStorageSync(STORAGE_KEY, this.data.actions);
    } catch (e) {}
  },

  // ==================== 编辑面板 ====================
  openAddEditor() {
    this.setData({
      showEditor: true,
      isEditMode: false,
      editingId: null,
      form: {
        name: '',
        deviceName: '',
        deviceMac: '',
        serviceUuid: '',
        charUuid: '',
        writeType: 'hex',
        value: '',
        color: 'blue',
      },
    });
  },

  openEditEditor(e) {
    const id = e.currentTarget.dataset.id;
    const action = this.data.actions.find(a => a.id === id);
    if (!action) return;
    this.setData({
      showEditor: true,
      isEditMode: true,
      editingId: id,
      form: {
        name: action.name,
        deviceName: action.deviceName || '',
        deviceMac: action.deviceMac || '',
        serviceUuid: action.serviceUuid || '',
        charUuid: action.charUuid || '',
        writeType: action.writeType || 'hex',
        value: action.value || '',
        color: action.color || 'blue',
      },
    });
  },

  closeEditor() {
    this.setData({ showEditor: false });
  },

  // 表单字段 input 统一处理
  onFormInput(e) {
    const field = e.currentTarget.dataset.field;
    const form = { ...this.data.form, [field]: e.detail.value };
    this.setData({ form });
  },

  switchWriteType(e) {
    const type = e.currentTarget.dataset.type;
    this.setData({ 'form.writeType': type });
  },

  selectColor(e) {
    const color = e.currentTarget.dataset.color;
    this.setData({ 'form.color': color });
  },

  // 填充当前已连接设备的 Mac，同时存储设备名
  fillConnectedDevice() {
    const d = app.globalData.connectedDevice;
    if (!d) {
      wx.showToast({ title: '当前无已连接设备', icon: 'none' });
      return;
    }
    this.setData({
      'form.deviceMac': d.deviceId,
      'form.deviceName': d.name || '',
    });
  },

  saveAction() {
    const { form, isEditMode, editingId, actions } = this.data;
    if (!form.name.trim()) {
      wx.showToast({ title: '请填写操作名称', icon: 'none' });
      return;
    }
    if (!form.charUuid.trim()) {
      wx.showToast({ title: '请填写特征值 UUID', icon: 'none' });
      return;
    }
    if (!form.value.trim()) {
      wx.showToast({ title: '请填写写入值', icon: 'none' });
      return;
    }

    if (isEditMode) {
      const updated = actions.map(a =>
        a.id === editingId ? { ...a, ...form, name: form.name.trim(), value: form.value.trim(), deviceName: form.deviceName || '' } : a
      );
      this.setData({ actions: updated, showEditor: false });
    } else {
      const newAction = {
        id: `qa_${Date.now()}`,
        name: form.name.trim(),
        deviceName: form.deviceName || '',   // 真实设备名（隐藏字段）
        deviceMac: form.deviceMac.trim(),
        serviceUuid: form.serviceUuid.trim(),
        charUuid: form.charUuid.trim(),
        writeType: form.writeType,
        value: form.value.trim(),
        color: form.color,
      };
      this.setData({ actions: [newAction, ...actions], showEditor: false });
    }
    this._saveActions();
  },

  deleteAction(e) {
    const id = e.currentTarget.dataset.id;
    const action = this.data.actions.find(a => a.id === id);
    wx.showModal({
      title: '删除操作',
      content: `确认删除「${action ? action.name : ''}」？`,
      confirmColor: '#e53935',
      success: (res) => {
        if (!res.confirm) return;
        const actions = this.data.actions.filter(a => a.id !== id);
        this.setData({ actions });
        this._saveActions();
      }
    });
  },

  // ==================== 一键执行 ====================
  executeAction(e) {
    const id = e.currentTarget.dataset.id;
    const action = this.data.actions.find(a => a.id === id);
    if (!action) return;

    // 生成新会话令牌，使所有旧的进行中流程自动失效
    const session = `s_${Date.now()}_${Math.random()}`;
    this._currentSession = session;

    this._setExecState(id, 'running', '连接中...');

    const connected = app.globalData.connectedDevice;
    const targetMac = action.deviceMac;

    // 已连接且 MAC 匹配（或未配置 MAC）→ 直接执行
    if (connected && (!targetMac || targetMac === connected.deviceId)) {
      this._doExecute(id, action, connected.deviceId, session);
      return;
    }

    // 有目标 MAC，但当前未连接或连接的不是目标设备
    if (targetMac) {
      const doConnect = () => this._scanAndConnect(id, action, targetMac, session);
      if (connected && connected.deviceId !== targetMac) {
        // 先停止扫描、解绑旧监听，再断开旧设备
        wx.stopBluetoothDevicesDiscovery({ complete: () => {} });
        wx.offBluetoothDeviceFound();
        // 清空全局状态（无论断开是否成功）
        app.globalData.connectedDevice = null;
        app.globalData.services = [];
        this.setData({ connectedDevice: null });
        // 超时兜底：3s 内 complete 未触发则直接继续
        let disconnected = false;
        const disconnectTimer = setTimeout(() => {
          if (!disconnected && this._currentSession === session) {
            disconnected = true;
            app.addLog('info', '', '[快捷] 断开超时，继续扫描', 'info');
            doConnect();
          }
        }, 3000);
        wx.closeBluetoothConnection({
          deviceId: connected.deviceId,
          complete: () => {
            if (disconnected) return; // 已由超时触发
            disconnected = true;
            clearTimeout(disconnectTimer);
            if (this._currentSession !== session) return;
            doConnect();
          }
        });
      } else {
        doConnect();
      }
      return;
    }

    // 无连接也无 MAC 配置
    this._execFail(id, '请先连接设备');
  },

  // 扫描并连接目标设备（直接走扫描，不做直连尝试，避免断开旧设备后的无效等待）
  _scanAndConnect(id, action, targetMac, session) {
    const doScan = () => {
      if (this._currentSession !== session) return;
      app.addLog('info', '', `[快捷] 扫描目标设备: ${targetMac}`, 'info');
      this._setExecState(id, 'running', '扫描中...');
      this._startScanForDevice(id, action, targetMac, session);
    };

    if (app.globalData.bluetoothInited) {
      doScan();
    } else {
      app.initBluetooth((ok) => {
        if (!ok || this._currentSession !== session) {
          if (!ok) this._execFail(id, '蓝牙未开启');
          return;
        }
        doScan();
      });
    }
  },

  // 获取真实设备名：优先用 getBluetoothDevices（缓存中含扫描到的完整信息）
  _resolveDeviceName(deviceId, cb) {
    wx.getBluetoothDevices({
      success: (res) => {
        const dev = res.devices.find(d => d.deviceId === deviceId);
        const name = dev ? (dev.name || dev.localName || '') : '';
        if (name) { cb(name); return; }
        // getBluetoothDevices 没有则再用 getConnectedBluetoothDevices 兜底
        wx.getConnectedBluetoothDevices({
          services: [],
          success: (r) => {
            const d2 = r.devices.find(d => d.deviceId === deviceId);
            cb(d2 ? (d2.name || d2.localName || '') : '');
          },
          fail: () => cb(''),
        });
      },
      fail: () => {
        // 直接兜底
        wx.getConnectedBluetoothDevices({
          services: [],
          success: (r) => {
            const d2 = r.devices.find(d => d.deviceId === deviceId);
            cb(d2 ? (d2.name || d2.localName || '') : '');
          },
          fail: () => cb(''),
        });
      },
    });
  },

  _startScanForDevice(id, action, targetMac, session) {
    let found = false;
    const TIMEOUT = 6000; // 6s 扫不到就报错，避免用户长时间等待

    const cleanup = () => {
      clearTimeout(timeoutTimer);
      wx.stopBluetoothDevicesDiscovery({ complete: () => {} });
      wx.offBluetoothDeviceFound();
    };

    // 超时兜底，防止永久卡在 running
    const timeoutTimer = setTimeout(() => {
      if (!found) {
        cleanup();
        if (this._currentSession === session) {
          this._execFail(id, '未找到目标设备');
        }
      }
    }, TIMEOUT);

    wx.startBluetoothDevicesDiscovery({
      allowDuplicatesKey: false,
      success: () => {
        if (this._currentSession !== session) {
          cleanup();
          return;
        }
        wx.onBluetoothDeviceFound(res => {
          if (found || this._currentSession !== session) {
            if (!found) { found = true; cleanup(); } // 会话失效时也要清理
            return;
          }
          const device = res.devices.find(d => d.deviceId === targetMac);
          if (!device) return;

          found = true;
          cleanup();

          const devInfo = {
            deviceId: device.deviceId,
            name: device.name || device.localName || action.name,
          };

          wx.createBLEConnection({
            deviceId: targetMac,
            timeout: 10000,
            success: () => {
              if (this._currentSession !== session) {
                wx.closeBluetoothConnection({ deviceId: targetMac, complete: () => {} });
                return;
              }
              app.globalData.connectedDevice = devInfo;
              app.globalData.services = [];
              this.setData({ connectedDevice: devInfo });
              app.addLog('info', '', `[快捷] 连接成功: ${devInfo.name}`, 'info');
              this._setExecState(id, 'running', '发现服务...');
              this._discoverAndExecute(id, action, targetMac, session);
            },
            fail: (err) => {
              if (this._currentSession !== session) return;
              app.addLog('error', '', `[快捷] 连接失败: ${err.errMsg}`, 'error');
              this._execFail(id, '连接失败');
            }
          });
        });
      },
      fail: () => {
        clearTimeout(timeoutTimer);
        if (this._currentSession === session) {
          this._execFail(id, '扫描失败');
        }
      }
    });
  },

  // 连接成功后：先做 GATT 服务发现，再执行写入
  _discoverAndExecute(id, action, deviceId, session) {
    if (this._currentSession !== session) return; // 会话已失效

    // 超时兜底：15s 内服务发现未完成则直接尝试写入
    const fallbackTimer = setTimeout(() => {
      if (this._currentSession !== session) return;
      app.addLog('info', '', '[快捷] 服务发现超时，直接写入', 'info');
      this._doExecute(id, action, deviceId, session);
    }, 15000);

    wx.getBLEDeviceServices({
      deviceId,
      success: (res) => {
        if (this._currentSession !== session) { clearTimeout(fallbackTimer); return; }
        app.globalData.services = res.services;
        const services = res.services;
        if (services.length === 0) {
          clearTimeout(fallbackTimer);
          this._doExecute(id, action, deviceId, session);
          return;
        }
        let pending = services.length;
        services.forEach(svc => {
          wx.getBLEDeviceCharacteristics({
            deviceId,
            serviceId: svc.uuid,
            complete: () => {
              pending--;
              if (pending === 0) {
                clearTimeout(fallbackTimer);
                if (this._currentSession !== session) return;
                this._doExecute(id, action, deviceId, session);
              }
            }
          });
        });
      },
      fail: (err) => {
        clearTimeout(fallbackTimer);
        if (this._currentSession !== session) return;
        app.addLog('info', '', `[快捷] 服务发现失败(${err.errMsg})，直接写入`, 'info');
        this._doExecute(id, action, deviceId, session);
      }
    });
  },

  // （已在 onLoad 统一注册）
  _registerConnectionStateChange() {},

  _setExecState(id, state, hint) {
    const execState = { ...this.data.execState, [id]: state };
    const execHint  = { ...this.data.execHint,  [id]: hint || '' };
    this.setData({ execState, execHint });
  },

  _doExecute(id, action, deviceId, session) {
    if (session !== undefined && this._currentSession !== session) return;
    // 构建 buffer
    let buffer;
    try {
      buffer = action.writeType === 'hex'
        ? this._hexToBuffer(action.value)
        : this._textToBuffer(action.value);
    } catch (e) {
      this._execFail(id, '数据格式错误');
      return;
    }

    const hexStr = this._bufferToHex(buffer);
    const serviceId = action.serviceUuid || undefined;
    const charUuid = action.charUuid;

    // 如果没有配置 serviceUuid，需要先枚举找到该特征值
    if (!serviceId) {
      this._findServiceAndWrite(id, action, deviceId, charUuid, buffer, hexStr);
      return;
    }

    this._writeBLE(id, action, deviceId, serviceId, charUuid, buffer, hexStr, false);
  },

  // 无 serviceUuid 时，枚举所有服务找到特征值
  _findServiceAndWrite(id, action, deviceId, charUuid, buffer, hexStr) {
    wx.getBLEDeviceServices({
      deviceId,
      success: (res) => {
        const services = res.services;
        let found = false;
        let pending = services.length;
        if (pending === 0) { this._execFail(id, '未找到服务'); return; }

        services.forEach(svc => {
          wx.getBLEDeviceCharacteristics({
            deviceId,
            serviceId: svc.uuid,
            success: (r) => {
              if (found) return;
              const match = r.characteristics.find(c => c.uuid === charUuid && (c.properties.write || c.properties.writeNoResponse));
              if (match) {
                found = true;
                this._writeBLE(id, action, deviceId, svc.uuid, charUuid, buffer, hexStr, false);
              }
            },
            complete: () => {
              pending--;
              if (pending === 0 && !found) {
                this._execFail(id, '未找到特征值');
              }
            }
          });
        });
      },
      fail: () => this._execFail(id, '获取服务失败'),
    });
  },

  _writeBLE(id, action, deviceId, serviceId, charUuid, buffer, hexStr, retryCount) {
    retryCount = retryCount || 0;
    wx.writeBLECharacteristicValue({
      deviceId,
      serviceId,
      characteristicId: charUuid,
      value: buffer,
      // 首次用 write，重试用 writeNoResponse
      writeType: retryCount >= 2 ? 'writeNoResponse' : 'write',
      success: () => {
        app.addLog('send', charUuid, `[快捷] ${action.name}: ${hexStr}`);
        this._execOk(id);
      },
      fail: (err) => {
        const errMsg = err.errMsg || '';
        const isEncryptErr = err.errno === 10008 || errMsg.includes('10008') || errMsg.includes('Encryption');
        const isNoRespErr  = errMsg.includes('writeNoResponse') || errMsg.includes('write no response');

        // 第一次遇到加密错误 → 尝试配对
        if (retryCount === 0 && isEncryptErr) {
          if (wx.makeBluetoothPair) {
            wx.showToast({ title: '设备需要配对，请在系统弹窗确认', icon: 'none', duration: 3000 });
            wx.makeBluetoothPair({
              deviceId,
              timeout: 20000,
              success: () => {
                // 等待系统完成配对绑定再重试
                setTimeout(() => {
                  this._writeBLE(id, action, deviceId, serviceId, charUuid, buffer, hexStr, 1);
                }, 1000);
              },
              fail: (pairErr) => {
                // makeBluetoothPair 不可用（如 BLE 服务端模式），静默降级直接重试
                app.addLog('info', charUuid, `配对API不可用(${pairErr.errMsg})，降级重试...`);
                this._writeBLE(id, action, deviceId, serviceId, charUuid, buffer, hexStr, 1);
              },
            });
          } else {
            // 不支持配对 API，直接重试
            this._writeBLE(id, action, deviceId, serviceId, charUuid, buffer, hexStr, 1);
          }
          return;
        }

        // 已配对但 write 失败 → 降级用 writeNoResponse
        if (retryCount === 1 && (isEncryptErr || isNoRespErr)) {
          this._writeBLE(id, action, deviceId, serviceId, charUuid, buffer, hexStr, 2);
          return;
        }

        // 最终失败
        app.addLog('error', charUuid, `[快捷] ${action.name} 失败: ${errMsg}`);
        this._execFail(id, '写入失败');
      }
    });
  },

  _execOk(id) {
    this._setExecState(id, 'ok', '');
    setTimeout(() => { this._setExecState(id, 'idle', ''); }, 2000);
  },

  _execFail(id, msg) {
    this._setExecState(id, 'err', '');
    wx.showToast({ title: msg || '执行失败', icon: 'none', duration: 2000 });
    setTimeout(() => { this._setExecState(id, 'idle', ''); }, 2500);
  },

  _execIdle(id) {
    const execState = { ...this.data.execState, [id]: 'idle' };
    this.setData({ execState });
  },

  // ==================== Utils ====================
  _hexToBuffer(hex) {
    const cleaned = hex.replace(/\s+/g, '');
    if (cleaned.length % 2 !== 0) throw new Error('invalid hex');
    const bytes = [];
    for (let i = 0; i < cleaned.length; i += 2) {
      const b = parseInt(cleaned.slice(i, i + 2), 16);
      if (isNaN(b)) throw new Error('invalid hex');
      bytes.push(b);
    }
    const buf = new ArrayBuffer(bytes.length);
    const view = new DataView(buf);
    bytes.forEach((b, i) => view.setUint8(i, b));
    return buf;
  },

  _textToBuffer(text) {
    const buf = new ArrayBuffer(text.length);
    const view = new DataView(buf);
    for (let i = 0; i < text.length; i++) view.setUint8(i, text.charCodeAt(i));
    return buf;
  },

  _bufferToHex(buffer) {
    const view = new DataView(buffer);
    let hex = '';
    for (let i = 0; i < view.byteLength; i++) {
      hex += view.getUint8(i).toString(16).padStart(2, '0').toUpperCase() + ' ';
    }
    return hex.trim();
  },

  // 颜色配置辅助
  getColorConfig(key) {
    return this.data.colorOptions.find(c => c.key === key) || this.data.colorOptions[0];
  },
});

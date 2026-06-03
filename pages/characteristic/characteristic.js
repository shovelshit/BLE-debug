// pages/characteristic/characteristic.js
const app = getApp();
const { PRESETS_KEY, getPresetDefault } = require('../../constants/storageDefaults');

Page({
  data: {
    deviceId: '',
    serviceId: '',
    charUuid: '',
    properties: {},

    // 读取的值
    readValue: '',
    readHex: '',

    // 写入的值
    writeInput: '',
    writeType: 'hex', // 'hex' | 'text'

    // 预设值
    presets: [],        // [{id, name, value, type}]
    showPresets: false, // 是否展开预设面板
    editingIdx: -1,     // 当前内联编辑的预设下标，-1 表示无
    editingName: '',    // 编辑中的名称
    editingValue: '',   // 编辑中的值

    // 通知状态
    notifyEnabled: false,
    notifyData: [],   // 最近 N 条通知数据

    // 操作状态
    isReading: false,
    isWriting: false,

    // 日志面板
    logPanelExpanded: true,
    logFilter: 'all',
    charLogs: [],
    filteredCharLogs: [],
  },

  onLoad(options) {
    const { deviceId, serviceId, charUuid, properties } = options;
    let props = {};
    try { props = JSON.parse(properties); } catch (e) {}

    const uuid = decodeURIComponent(charUuid || '');
    this.setData({
      deviceId,
      serviceId: decodeURIComponent(serviceId || ''),
      charUuid: uuid,
      properties: props,
    });
    this._loadPresets();
  },

  onShow() {
    this._refreshCharLogs();
    this._logTimer = setInterval(() => this._refreshCharLogs(), 600);
  },

  onHide() {
    clearInterval(this._logTimer);
  },

  onUnload() {
    clearInterval(this._logTimer);
    // 页面退出时关闭 Notify（如果已开启）
    if (this.data.notifyEnabled) {
      this._toggleNotifyOff();
    }
    wx.offBLECharacteristicValueChange();
  },

  // ===================== READ =====================
  readValue() {
    if (!this.data.properties.read) {
      wx.showToast({ title: '该特征值不支持 Read', icon: 'none' });
      return;
    }
    this.setData({ isReading: true });

    wx.readBLECharacteristicValue({
      deviceId: this.data.deviceId,
      serviceId: this.data.serviceId,
      characteristicId: this.data.charUuid,
      success: () => {
        // 结果通过 onBLECharacteristicValueChange 回调返回
        wx.onBLECharacteristicValueChange(res => {
          if (res.characteristicId === this.data.charUuid) {
            const hex = this._bufferToHex(res.value);
            const text = this._bufferToText(res.value);
            this.setData({
              readHex: hex,
              readValue: text,
              isReading: false,
            });
            app.addLog('recv', this.data.charUuid, hex);
          }
        });
      },
      fail: (err) => {
        this.setData({ isReading: false });
        const isEncryptErr = err.errno === 10008 || (err.errMsg && err.errMsg.includes('10008'));
        app.addLog('error', this.data.charUuid, `Read 失败: ${err.errMsg}`);
        wx.showToast({
          title: isEncryptErr ? '设备需要配对，请先发送写操作触发配对' : 'Read 失败',
          icon: 'none',
          duration: 3000
        });
      }
    });
  },

  // ===================== WRITE =====================
  onWriteInput(e) {
    this.setData({ writeInput: e.detail.value });
  },

  switchWriteType(e) {
    this.setData({ writeType: e.currentTarget.dataset.type, writeInput: '' });
  },

  writeValue() {
    const { writeInput, writeType, properties } = this.data;
    if (!writeInput.trim()) {
      wx.showToast({ title: '请输入数据', icon: 'none' });
      return;
    }
    if (!properties.write && !properties.writeNoResponse) {
      wx.showToast({ title: '该特征值不支持 Write', icon: 'none' });
      return;
    }

    let buffer;
    try {
      buffer = writeType === 'hex' ? this._hexToBuffer(writeInput) : this._textToBuffer(writeInput);
    } catch (e) {
      wx.showToast({ title: '数据格式错误', icon: 'none' });
      return;
    }

    this.setData({ isWriting: true });
    const hexStr = this._bufferToHex(buffer);

    this._doWrite(buffer, hexStr, properties.write ? 'write' : 'writeNoResponse');
  },

  // 执行写入，支持加密不足时自动配对重试
  _doWrite(buffer, hexStr, writeType, isRetry = false) {
    wx.writeBLECharacteristicValue({
      deviceId: this.data.deviceId,
      serviceId: this.data.serviceId,
      characteristicId: this.data.charUuid,
      value: buffer,
      writeType,
      success: () => {
        this.setData({ isWriting: false });
        app.addLog('send', this.data.charUuid, hexStr);
        wx.showToast({ title: '写入成功', icon: 'success' });
      },
      fail: (err) => {
        // errCode 10008: Encryption is insufficient，需先配对
        if (!isRetry && (err.errno === 10008 || (err.errMsg && err.errMsg.includes('10008')))) {
          app.addLog('info', this.data.charUuid, '设备需要配对，正在请求配对...', 'info');
          this._requestPairAndRetry(buffer, hexStr, writeType);
        } else {
          this.setData({ isWriting: false });
          app.addLog('error', this.data.charUuid, `Write 失败: ${err.errMsg}`);
          wx.showToast({ title: '写入失败', icon: 'none' });
        }
      }
    });
  },

  // 触发系统配对，配对成功/失败都降级重试写入
  _requestPairAndRetry(buffer, hexStr, writeType) {
    if (wx.makeBluetoothPair) {
      wx.showToast({ title: '设备需要配对，请在系统弹窗确认', icon: 'none', duration: 3000 });
      wx.makeBluetoothPair({
        deviceId: this.data.deviceId,
        timeout: 20000,
        success: () => {
          app.addLog('info', this.data.charUuid, '配对成功，重试写入...', 'info');
          // 等待系统完成绑定后再重试
          setTimeout(() => this._doWrite(buffer, hexStr, writeType, true), 1000);
        },
        fail: (pairErr) => {
          // makeBluetoothPair 不可用（如 BLE 服务端模式），静默降级直接重试
          app.addLog('info', this.data.charUuid, `配对API不可用(${pairErr.errMsg})，降级重试...`, 'info');
          this._doWrite(buffer, hexStr, writeType, true);
        }
      });
    } else {
      // 低版本基础库无 makeBluetoothPair，直接重试
      this._doWrite(buffer, hexStr, writeType, true);
    }
  },

  // ===================== NOTIFY =====================
  toggleNotify() {
    const { properties, notifyEnabled } = this.data;
    if (!properties.notify && !properties.indicate) {
      wx.showToast({ title: '该特征值不支持 Notify', icon: 'none' });
      return;
    }
    if (notifyEnabled) {
      this._toggleNotifyOff();
    } else {
      this._toggleNotifyOn();
    }
  },

  _toggleNotifyOn() {
    wx.notifyBLECharacteristicValueChange({
      deviceId: this.data.deviceId,
      serviceId: this.data.serviceId,
      characteristicId: this.data.charUuid,
      state: true,
      success: () => {
        this.setData({ notifyEnabled: true });
        app.addLog('info', this.data.charUuid, 'Notify 已开启', 'info');
        wx.onBLECharacteristicValueChange(res => {
          if (res.characteristicId === this.data.charUuid) {
            const hex = this._bufferToHex(res.value);
            const time = this._getTimeStr();
            const notifyData = this.data.notifyData;
            notifyData.unshift({ hex, time, id: Date.now() });
            if (notifyData.length > 50) notifyData.pop();
            this.setData({ notifyData });
            app.addLog('recv', this.data.charUuid, hex);
          }
        });
      },
      fail: (err) => {
        const isEncryptErr = err.errno === 10008 || (err.errMsg && err.errMsg.includes('10008'));
        app.addLog('error', this.data.charUuid, `Notify 开启失败: ${err.errMsg}`);
        wx.showToast({
          title: isEncryptErr ? '设备需要配对，请先通过 Write 触发配对' : 'Notify 开启失败',
          icon: 'none',
          duration: 3000
        });
      }
    });
  },

  _toggleNotifyOff() {
    wx.notifyBLECharacteristicValueChange({
      deviceId: this.data.deviceId,
      serviceId: this.data.serviceId,
      characteristicId: this.data.charUuid,
      state: false,
      success: () => {
        this.setData({ notifyEnabled: false });
        app.addLog('info', this.data.charUuid, 'Notify 已关闭', 'info');
      },
      fail: () => {}
    });
    wx.offBLECharacteristicValueChange();
  },

  clearNotifyData() {
    this.setData({ notifyData: [] });
  },

  // ===================== Utils =====================
  _bufferToHex(buffer) {
    const view = new DataView(buffer);
    let hex = '';
    for (let i = 0; i < view.byteLength; i++) {
      hex += view.getUint8(i).toString(16).padStart(2, '0').toUpperCase() + ' ';
    }
    return hex.trim();
  },

  _bufferToText(buffer) {
    try {
      const bytes = new Uint8Array(buffer);
      return Array.from(bytes).map(b => b >= 32 && b < 127 ? String.fromCharCode(b) : '.').join('');
    } catch (e) {
      return '';
    }
  },

  _hexToBuffer(hex) {
    // 支持 "AA BB CC" 或 "AABBCC" 格式
    const cleaned = hex.replace(/\s+/g, '');
    if (cleaned.length % 2 !== 0) throw new Error('invalid hex');
    const bytes = [];
    for (let i = 0; i < cleaned.length; i += 2) {
      const byte = parseInt(cleaned.slice(i, i + 2), 16);
      if (isNaN(byte)) throw new Error('invalid hex');
      bytes.push(byte);
    }
    const buffer = new ArrayBuffer(bytes.length);
    const view = new DataView(buffer);
    bytes.forEach((b, i) => view.setUint8(i, b));
    return buffer;
  },

  _textToBuffer(text) {
    const buffer = new ArrayBuffer(text.length);
    const view = new DataView(buffer);
    for (let i = 0; i < text.length; i++) {
      view.setUint8(i, text.charCodeAt(i));
    }
    return buffer;
  },

  _getTimeStr() {
    const now = new Date();
    const pad = n => String(n).padStart(2, '0');
    return `${pad(now.getHours())}:${pad(now.getMinutes())}:${pad(now.getSeconds())}.${String(now.getMilliseconds()).padStart(3, '0')}`;
  },

  shortUUID(uuid) {
    if (!uuid) return '';
    const parts = uuid.split('-');
    return parts[0] ? parts[0].toUpperCase() : uuid.substring(0, 8).toUpperCase();
  },

copyUUID() {
wx.setClipboardData({
data: this.data.charUuid,
success: () => wx.showToast({ title: '已复制', icon: 'success' })
});
},

copyServiceUUID() {
wx.setClipboardData({
data: this.data.serviceId,
success: () => wx.showToast({ title: '已复制', icon: 'success' })
});
},

// 跳转到快捷操作页并预填当前特征值信息
// 快捷页是 TabBar 页，switchTab 不支持传参，改用 globalData 中转
addToQuick() {
const { deviceId, serviceId, charUuid, writeInput, writeType } = this.data;
const device = app.globalData.connectedDevice;
app.globalData._quickPrefill = {
  deviceMac:   deviceId,
  serviceUuid: serviceId,
  charUuid,
  writeType,
  value:       writeInput || '',
  deviceName:  (device && device.name) || '',
};
wx.switchTab({ url: '/pages/quick/quick' });
},

  // ===================== 预设值 =====================
  _storageKey() {
    return PRESETS_KEY;
  },

  _loadPresets() {
    try {
      const raw = wx.getStorageSync(this._storageKey());
      this.setData({ presets: Array.isArray(raw) ? raw : getPresetDefault() });
    } catch (e) {
      this.setData({ presets: getPresetDefault() });
    }
  },

  _savePresets() {
    try {
      wx.setStorageSync(this._storageKey(), this.data.presets);
    } catch (e) {}
  },

  togglePresets() {
    this.setData({ showPresets: !this.data.showPresets });
  },

  // 点击预设 → 填充到输入框
  applyPreset(e) {
    const { value, type } = e.currentTarget.dataset;
    this.setData({ writeInput: value, writeType: type });
  },

  // 保存当前输入为预设
  addPreset() {
    const { writeInput, writeType, presets } = this.data;
    if (!writeInput.trim()) {
      wx.showToast({ title: '请先输入内容', icon: 'none' });
      return;
    }
    // 重名检测
    if (presets.some(p => p.name === writeInput.trim() && p.type === writeType)) {
      wx.showToast({ title: '预设已存在', icon: 'none' });
      return;
    }
    wx.showModal({
      title: '保存预设',
      editable: true,
      placeholderText: '输入预设名称（可留空）',
      success: (res) => {
        if (!res.confirm) return;
        const name = (res.content || '').trim() || writeInput.trim().slice(0, 12);
        const newPresets = [
          { id: Date.now(), name, value: writeInput.trim(), type: writeType },
          ...presets,
        ];
        this.setData({ presets: newPresets, showPresets: true });
        this._savePresets();
        wx.showToast({ title: '已保存', icon: 'success' });
      }
    });
  },

  // 长按预设 → 弹出操作菜单（填充 / 编辑 / 删除）
  onPresetLongPress(e) {
    const idx = e.currentTarget.dataset.idx;
    const preset = this.data.presets[idx];
    wx.showActionSheet({
      itemList: ['填充到输入框', '编辑预设', '删除预设'],
      success: (res) => {
        if (res.tapIndex === 0) {
          this.setData({ writeInput: preset.value, writeType: preset.type });
        } else if (res.tapIndex === 1) {
          this.editPreset({ currentTarget: { dataset: { idx } } });
        } else if (res.tapIndex === 2) {
          this.deletePreset({ currentTarget: { dataset: { idx } } });
        }
      }
    });
  },

  deletePreset(e) {
    const idx = e.currentTarget.dataset.idx;
    wx.showModal({
      title: '删除预设',
      content: `确认删除「${this.data.presets[idx].name}」？`,
      confirmColor: '#e53935',
      success: (res) => {
        if (!res.confirm) return;
        const presets = this.data.presets.filter((_, i) => i !== idx);
        this.setData({ presets });
        this._savePresets();
        wx.showToast({ title: '已删除', icon: 'success' });
      }
    });
  },

  // 进入内联编辑态
  editPreset(e) {
    const idx = e.currentTarget.dataset.idx;
    const preset = this.data.presets[idx];
    this.setData({
      editingIdx: idx,
      editingName: preset.name,
      editingValue: preset.value,
    });
  },

  onEditNameInput(e) {
    this.setData({ editingName: e.detail.value });
  },

  onEditValueInput(e) {
    this.setData({ editingValue: e.detail.value });
  },

  // 确认保存编辑
  confirmEditPreset(e) {
    const idx = e.currentTarget.dataset.idx;
    const { editingName, editingValue, presets } = this.data;
    if (!editingValue.trim()) {
      wx.showToast({ title: '值不能为空', icon: 'none' });
      return;
    }
    const updated = [...presets];
    updated[idx] = {
      ...updated[idx],
      name: editingName.trim() || editingValue.trim().slice(0, 12),
      value: editingValue.trim(),
    };
    this.setData({ presets: updated, editingIdx: -1, editingName: '', editingValue: '' });
    this._savePresets();
    wx.showToast({ title: '已更新', icon: 'success' });
  },

  // 取消编辑
  cancelEditPreset() {
    this.setData({ editingIdx: -1, editingName: '', editingValue: '' });
  },

  // ===================== 日志面板 =====================
  _refreshCharLogs() {
    // 只显示与当前特征值 UUID 相关的日志
    const uuid = this.data.charUuid;
    const all = app.globalData.logs || [];
    // 优先过滤当前特征值，若无则显示全部
    const charLogs = uuid ? all.filter(l => !l.uuid || l.uuid === uuid) : all;
    this.setData({ charLogs });
    this._applyCharLogFilter(charLogs);
  },

  _applyCharLogFilter(logs) {
    const filter = this.data.logFilter;
    const filteredCharLogs = filter === 'all' ? logs : logs.filter(l => l.direction === filter);
    this.setData({ filteredCharLogs });
  },

  toggleLogPanel() {
    this.setData({ logPanelExpanded: !this.data.logPanelExpanded });
  },

  switchLogFilter(e) {
    const filter = e.currentTarget.dataset.filter;
    this.setData({ logFilter: filter });
    this._applyCharLogFilter(this.data.charLogs);
  },

  clearCharLogs() {
    wx.showModal({
      title: '清空日志',
      content: '确认清空所有通信日志？',
      success: (res) => {
        if (res.confirm) {
          app.globalData.logs = [];
          this.setData({ charLogs: [], filteredCharLogs: [] });
        }
      }
    });
  },

  copyCharLog(e) {
    const log = e.currentTarget.dataset.log;
    const text = `[${log.time}] ${log.direction.toUpperCase()} ${log.uuid ? log.uuid + ' ' : ''}${log.data}`;
    wx.setClipboardData({
      data: text,
      success: () => wx.showToast({ title: '已复制', icon: 'success' })
    });
  },
});

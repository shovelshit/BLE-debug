// pages/device/device.js
const app = getApp();

Page({
  data: {
    deviceId: '',
    deviceName: '',
    isConnected: true,
    services: [],
    expandedServices: {}, // 记录展开状态
    loading: false,

    // 日志面板
    logPanelExpanded: true,  // 默认展开
    logFilter: 'all',        // 'all' | 'send' | 'recv' | 'info' | 'error'
    deviceLogs: [],          // 当前设备相关日志（全部）
    filteredDeviceLogs: [],  // 过滤后的日志
  },

  onLoad(options) {
    const { deviceId, deviceName } = options;
    this.setData({
      deviceId,
      deviceName: decodeURIComponent(deviceName || ''),
    });
    this._loadServices();
  },

  onShow() {
    const connectedDevice = app.globalData.connectedDevice;
    const isConnected = connectedDevice && connectedDevice.deviceId === this.data.deviceId;
    this.setData({ isConnected: !!isConnected });

    // 刷新日志
    this._refreshLogs();
    // 定时轮询日志（600ms）
    this._logTimer = setInterval(() => this._refreshLogs(), 600);
  },

  onHide() {
    clearInterval(this._logTimer);
  },

  onUnload() {
    clearInterval(this._logTimer);
  },

  // 加载服务列表
  _loadServices() {
    // 如果 globalData 有缓存，直接使用
    if (app.globalData.services && app.globalData.services.length > 0) {
      this._buildServiceData(app.globalData.services);
      return;
    }
    this._discoverServices();
  },

  _discoverServices() {
    this.setData({ loading: true });
    app.addLog('info', '', `发现服务: ${this.data.deviceName}`, 'info');

    wx.getBLEDeviceServices({
      deviceId: this.data.deviceId,
      success: (res) => {
        const services = res.services;
        app.globalData.services = services;
        app.addLog('info', '', `发现 ${services.length} 个服务`, 'info');
        this._discoverAllCharacteristics(services);
      },
      fail: (err) => {
        this.setData({ loading: false });
        app.addLog('error', '', `获取服务失败: ${err.errMsg}`, 'error');
        wx.showToast({ title: '获取服务失败', icon: 'none' });
      }
    });
  },

  // 逐个获取每个服务的特征值
  _discoverAllCharacteristics(services) {
    const serviceList = services.map(s => ({ ...s, characteristics: [], expanded: false }));
    this.setData({ services: serviceList });

    let pending = services.length;
    if (pending === 0) {
      this.setData({ loading: false });
      return;
    }

    services.forEach((service, idx) => {
      wx.getBLEDeviceCharacteristics({
        deviceId: this.data.deviceId,
        serviceId: service.uuid,
        success: (res) => {
          const chars = res.characteristics.map(c => ({
            uuid: c.uuid,
            properties: c.properties,
            propertiesStr: this._propsToString(c.properties),
          }));

          const services = this.data.services;
          services[idx].characteristics = chars;
          this.setData({ services });
          app.addLog('info', service.uuid, `服务 ${this._shortUUID(service.uuid)}: ${chars.length} 个特征值`, 'info');
        },
        fail: (err) => {
          app.addLog('error', service.uuid, `获取特征值失败: ${err.errMsg}`, 'error');
        },
        complete: () => {
          pending--;
          if (pending === 0) {
            this.setData({ loading: false });
          }
        }
      });
    });
  },

  // 展开/折叠服务
  toggleService(e) {
    const idx = e.currentTarget.dataset.idx;
    const services = this.data.services;
    services[idx].expanded = !services[idx].expanded;
    this.setData({ services });
  },

  // 刷新服务
  refreshServices() {
    app.globalData.services = [];
    this.setData({ services: [] });
    this._discoverServices();
  },

  // 点击特征值 -> 跳转操作页
  openCharacteristic(e) {
    const { serviceId, charUuid, properties } = e.currentTarget.dataset;
    wx.navigateTo({
      url: `/pages/characteristic/characteristic?deviceId=${this.data.deviceId}&serviceId=${encodeURIComponent(serviceId)}&charUuid=${encodeURIComponent(charUuid)}&properties=${JSON.stringify(properties)}`
    });
  },

  // 断开连接
  disconnect() {
    wx.showModal({
      title: '断开连接',
      content: `确认断开与 ${this.data.deviceName} 的连接？`,
      success: (res) => {
        if (!res.confirm) return;

        const deviceId = this.data.deviceId;
        const deviceName = this.data.deviceName;

        // 立即清除全局状态并更新 UI，无需等蓝牙关闭完成
        app.globalData.connectedDevice = null;
        app.globalData.services = [];
        this.setData({ isConnected: false });
        clearInterval(this._logTimer);

        // 立刻返回，不阻塞在等待关闭
        app.addLog('info', '', `已断开: ${deviceName}`, 'info');
        wx.navigateBack();

        // 在后台异步关闭蓝牙连接
        wx.closeBluetoothConnection({ deviceId, complete: () => {} });
      }
    });
  },

  // 跳转到完整日志页
  viewLogs() {
    wx.switchTab({ url: '/pages/log/log' });
  },

  // ---- 日志面板 ----

  // 切换日志面板展开/收起
  toggleLogPanel() {
    this.setData({ logPanelExpanded: !this.data.logPanelExpanded });
  },

  // 刷新日志（轮询）
  _refreshLogs() {
    const allLogs = app.globalData.logs || [];
    this.setData({ deviceLogs: allLogs });
    this._applyLogFilter(allLogs);
  },

  // 过滤日志
  _applyLogFilter(logs) {
    const filter = this.data.logFilter;
    const filteredDeviceLogs = filter === 'all' ? logs : logs.filter(l => l.direction === filter);
    this.setData({ filteredDeviceLogs });
  },

  // 切换过滤标签
  switchLogFilter(e) {
    const filter = e.currentTarget.dataset.filter;
    this.setData({ logFilter: filter });
    this._applyLogFilter(this.data.deviceLogs);
  },

  // 长按复制 UUID（服务 / 特征值）
  copyUuid(e) {
    const uuid = e.currentTarget.dataset.uuid;
    if (!uuid) return;
    wx.setClipboardData({
      data: uuid,
      success: () => wx.showToast({ title: '已复制', icon: 'success' })
    });
  },

  // 长按复制日志
  copyDeviceLog(e) {
    const log = e.currentTarget.dataset.log;
    const text = `[${log.time}] ${log.direction.toUpperCase()} ${log.uuid ? log.uuid + ' ' : ''}${log.data}`;
    wx.setClipboardData({
      data: text,
      success: () => wx.showToast({ title: '已复制', icon: 'success' })
    });
  },

  // 清空日志
  clearDeviceLogs() {
    wx.showModal({
      title: '清空日志',
      content: '确认清空所有通信日志？',
      success: (res) => {
        if (res.confirm) {
          app.globalData.logs = [];
          this.setData({ deviceLogs: [], filteredDeviceLogs: [] });
        }
      }
    });
  },

  _propsToString(props) {
    const list = [];
    if (props.read) list.push('Read');
    if (props.write) list.push('Write');
    if (props.writeNoResponse) list.push('WriteNoResp');
    if (props.notify) list.push('Notify');
    if (props.indicate) list.push('Indicate');
    return list;
  },

  _shortUUID(uuid) {
    if (!uuid) return '';
    if (uuid.length === 4) return uuid.toUpperCase();
    // 标准 128bit UUID 取第一段
    const parts = uuid.split('-');
    if (parts.length >= 1) return parts[0].toUpperCase();
    return uuid.substring(0, 8).toUpperCase();
  },

  _buildServiceData(services) {
    // 从缓存构建（无特征值，触发重新获取）
    this._discoverAllCharacteristics(services);
  }
});

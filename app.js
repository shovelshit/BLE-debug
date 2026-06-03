// app.js
const { initStorageDefaults } = require('./constants/storageDefaults');

App({
  globalData: {
    // 当前连接的设备
    connectedDevice: null,
    // 设备的服务列表
    services: [],
    // 通信日志
    logs: [],
    // 蓝牙是否已初始化
    bluetoothInited: false,
  },

  onLaunch() {
    // 首次初始化：将默认数据写入 storage
    initStorageDefaults();

    // PC/Mac 微信不支持蓝牙，跳过初始化
    const { platform } = wx.getDeviceInfo ? wx.getDeviceInfo() : wx.getSystemInfoSync();
    this.globalData.platform = platform;
    if (platform === 'mac' || platform === 'windows' || platform === 'devtools') {
      console.warn('当前平台不支持蓝牙:', platform);
      this.globalData.bluetoothAvailable = false;
      return;
    }
    this.initBluetooth();
  },

  onHide() {
    // 切后台时仅断开设备连接，不关闭蓝牙适配器（避免回来时状态显示为关闭）
    this._disconnectDevice();
  },

  onUnload() {
    this._disconnectDevice();
    wx.closeBluetoothAdapter();
  },

  // 初始化蓝牙适配器，成功后更新全局状态
  initBluetooth(callback) {
    wx.openBluetoothAdapter({
      success: () => {
        console.log('蓝牙适配器初始化成功');
        this.globalData.bluetoothInited = true;
        this.globalData.bluetoothAvailable = true;
        callback && callback(true);
      },
      fail: (err) => {
        console.log('蓝牙适配器初始化失败', err);
        this.globalData.bluetoothInited = false;
        this.globalData.bluetoothAvailable = false;
        callback && callback(false);
      }
    });
  },

  // 仅断开已连接设备，不关闭适配器
  _disconnectDevice() {
    if (this.globalData.connectedDevice) {
      wx.closeBluetoothConnection({
        deviceId: this.globalData.connectedDevice.deviceId,
        complete: () => {}
      });
    }
  },

  // 添加日志
  addLog(direction, uuid, data, type = 'data') {
    const log = {
      id: Date.now(),
      time: this._getTimeStr(),
      direction, // 'send' | 'recv' | 'info' | 'error'
      uuid: uuid || '',
      data: data || '',
      type,
    };
    this.globalData.logs.unshift(log);
    // 最多保留 200 条
    if (this.globalData.logs.length > 200) {
      this.globalData.logs.pop();
    }
    return log;
  },

  _getTimeStr() {
    const now = new Date();
    const pad = n => String(n).padStart(2, '0');
    return `${pad(now.getHours())}:${pad(now.getMinutes())}:${pad(now.getSeconds())}.${String(now.getMilliseconds()).padStart(3, '0')}`;
  }
});

// pages/index/index.js
const app = getApp();

Page({
  data: {
    isScanning: false,
    devices: [],         // 扫描到的设备列表（全部）
    filteredDevices: [], // 过滤后的设备列表
    filterEmpty: false,  // 是否过滤无名称设备
    connectedDeviceId: null,
    bluetoothState: 'unknown', // 'unknown' | 'on' | 'off' | 'unsupported'
    isUnsupported: false,      // 当前平台不支持蓝牙
  },

  onLoad() {
    this._deviceMap = {}; // 用于去重
    this._checkBluetoothState();
  },

  onShow() {
    const connectedDevice = app.globalData.connectedDevice;
    this.setData({
      connectedDeviceId: connectedDevice ? connectedDevice.deviceId : null,
    });
    // 每次显示都重新检查蓝牙状态（修复从后台回来显示关闭的问题）
    this._checkBluetoothState();
    // 监听蓝牙状态变化
    wx.onBluetoothAdapterStateChange(res => {
      this.setData({ bluetoothState: res.available ? 'on' : 'off' });
      if (!res.available && this.data.isScanning) {
        this._stopScan();
      }
    });
  },

  onUnload() {
    this._stopScan();
    wx.offBluetoothAdapterStateChange();
  },

  // 检查蓝牙状态：先判断平台是否支持，再查询适配器
  _checkBluetoothState() {
    const platform = app.globalData.platform || '';
    // Mac / Windows / 开发者工具不支持蓝牙
    if (platform === 'mac' || platform === 'windows' || platform === 'devtools') {
      this.setData({ bluetoothState: 'unsupported', isUnsupported: true });
      return;
    }

    wx.getBluetoothAdapterState({
      success: (res) => {
        this.setData({ bluetoothState: res.available ? 'on' : 'off' });
      },
      fail: () => {
        // 适配器未初始化，尝试初始化并等回调再更新状态
        app.initBluetooth((ok) => {
          this.setData({ bluetoothState: ok ? 'on' : 'off' });
        });
      }
    });
  },

  // 开始/停止扫描
  toggleScan() {
    if (this.data.isScanning) {
      this._stopScan();
    } else {
      this._startScan();
    }
  },

  _startScan() {
    if (this.data.bluetoothState !== 'on') {
      wx.showToast({ title: '请先开启蓝牙', icon: 'none' });
      // 尝试重新初始化并刷新状态
      this._checkBluetoothState();
      return;
    }

    this._deviceMap = {};
    this.setData({ devices: [], filteredDevices: [], isScanning: true });
    app.addLog('info', '', '开始扫描设备...', 'info');

    wx.startBluetoothDevicesDiscovery({
      allowDuplicatesKey: false,
      success: () => {
        wx.onBluetoothDeviceFound(res => {
          res.devices.forEach(device => {
            const id = device.deviceId;
            if (!id) return;

            // 更新或新增
            if (this._deviceMap[id]) {
              // 更新 RSSI
              this._deviceMap[id] = { ...this._deviceMap[id], RSSI: device.RSSI };
            } else {
              this._deviceMap[id] = {
                deviceId: id,
                name: device.name || device.localName || '',
                RSSI: device.RSSI,
                advertisServiceUUIDs: device.advertisServiceUUIDs || [],
              };
            }
          });

          // 按信号强度排序
          const devices = Object.values(this._deviceMap).sort((a, b) => b.RSSI - a.RSSI);
          const filteredDevices = this._applyFilter(devices);
          this.setData({ devices, filteredDevices });
        });
      },
      fail: (err) => {
        this.setData({ isScanning: false });
        wx.showToast({ title: '扫描失败: ' + (err.errMsg || ''), icon: 'none' });
      }
    });
  },

  _stopScan() {
    wx.stopBluetoothDevicesDiscovery({
      complete: () => {
        wx.offBluetoothDeviceFound();
        this.setData({ isScanning: false });
        app.addLog('info', '', `扫描结束，发现 ${this.data.devices.length} 个设备`, 'info');
      }
    });
  },

  // 过滤逻辑：过滤掉无名称的设备
  _applyFilter(devices) {
    if (!this.data.filterEmpty) return devices;
    return devices.filter(d => d.name && d.name.trim() !== '');
  },

  // 切换过滤空设备
  toggleFilterEmpty() {
    const filterEmpty = !this.data.filterEmpty;
    const filteredDevices = filterEmpty
      ? this.data.devices.filter(d => d.name && d.name.trim() !== '')
      : this.data.devices;
    this.setData({ filterEmpty, filteredDevices });
  },

  // 选择设备 -> 连接（使用 filteredDevices 里的设备，也传 name）
  selectDevice(e) {
    const device = e.currentTarget.dataset.device;
    // 如果设备名为空，显示"未知设备"
    if (!device.name || device.name.trim() === '') {
      device.name = '未知设备';
    }
    if (this.data.isScanning) this._stopScan();

    // 如果当前已连接该设备，直接跳转
    if (this.data.connectedDeviceId === device.deviceId) {
      wx.navigateTo({ url: `/pages/device/device?deviceId=${device.deviceId}&deviceName=${encodeURIComponent(device.name)}` });
      return;
    }

    // 如果连接了其他设备，先断开
    if (this.data.connectedDeviceId && this.data.connectedDeviceId !== device.deviceId) {
      wx.showModal({
        title: '提示',
        content: '已连接其他设备，是否断开并连接新设备？',
        success: (res) => {
          if (res.confirm) {
            this._disconnectAndConnect(device);
          }
        }
      });
      return;
    }

    this._connectDevice(device);
  },

  _disconnectAndConnect(device) {
    wx.closeBluetoothConnection({
      deviceId: this.data.connectedDeviceId,
      complete: () => {
        app.globalData.connectedDevice = null;
        app.globalData.services = [];
        this.setData({ connectedDeviceId: null });
        this._connectDevice(device);
      }
    });
  },

  _connectDevice(device) {
    wx.showLoading({ title: '连接中...' });
    app.addLog('info', '', `正在连接: ${device.name} (${device.deviceId})`, 'info');

    wx.createBLEConnection({
      deviceId: device.deviceId,
      timeout: 10000,
      success: () => {
        wx.hideLoading();
        app.globalData.connectedDevice = device;
        app.globalData.services = [];
        this.setData({ connectedDeviceId: device.deviceId });
        app.addLog('info', '', `已连接: ${device.name}`, 'info');

        wx.showToast({ title: '连接成功', icon: 'success' });

        // 监听连接状态变化
        wx.onBLEConnectionStateChange(res => {
          if (!res.connected && res.deviceId === device.deviceId) {
            app.globalData.connectedDevice = null;
            app.globalData.services = [];
            this.setData({ connectedDeviceId: null });
            app.addLog('info', '', `设备断开: ${device.name}`, 'info');
            wx.showToast({ title: '设备已断开', icon: 'none' });
          }
        });

        wx.navigateTo({
          url: `/pages/device/device?deviceId=${device.deviceId}&deviceName=${encodeURIComponent(device.name)}`
        });
      },
      fail: (err) => {
        wx.hideLoading();
        app.addLog('error', '', `连接失败: ${err.errMsg}`, 'error');
        wx.showToast({ title: '连接失败', icon: 'none' });
      }
    });
  },

  // 清空设备列表
  clearDevices() {
    this._deviceMap = {};
    this.setData({ devices: [], filteredDevices: [] });
  },
});

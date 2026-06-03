// pages/log/log.js
const app = getApp();

Page({
  data: {
    logs: [],
    filter: 'all', // 'all' | 'send' | 'recv' | 'info' | 'error'
    filteredLogs: [],
  },

  onShow() {
    this._refreshLogs();
    // 定时刷新（500ms 轮询）
    this._timer = setInterval(() => this._refreshLogs(), 500);
  },

  onHide() {
    clearInterval(this._timer);
  },

  onUnload() {
    clearInterval(this._timer);
  },

  _refreshLogs() {
    const logs = app.globalData.logs || [];
    this.setData({ logs });
    this._applyFilter(logs);
  },

  _applyFilter(logs) {
    const filter = this.data.filter;
    const filteredLogs = filter === 'all' ? logs : logs.filter(l => l.direction === filter);
    this.setData({ filteredLogs });
  },

  switchFilter(e) {
    const filter = e.currentTarget.dataset.filter;
    this.setData({ filter });
    this._applyFilter(this.data.logs);
  },

  clearLogs() {
    wx.showModal({
      title: '清空日志',
      content: '确认清空所有通信日志？',
      success: (res) => {
        if (res.confirm) {
          app.globalData.logs = [];
          this.setData({ logs: [], filteredLogs: [] });
        }
      }
    });
  },

  copyLog(e) {
    const log = e.currentTarget.dataset.log;
    const text = `[${log.time}] ${log.direction.toUpperCase()} ${log.uuid ? log.uuid + ' ' : ''}${log.data}`;
    wx.setClipboardData({
      data: text,
      success: () => wx.showToast({ title: '已复制', icon: 'success' })
    });
  },

  // 导出日志（复制全部到剪贴板）
  exportLogs() {
    const logs = this.data.filteredLogs;
    if (logs.length === 0) {
      wx.showToast({ title: '日志为空', icon: 'none' });
      return;
    }
    const text = logs.map(l =>
      `[${l.time}] ${l.direction.padEnd(5)} ${l.uuid ? l.uuid.substring(0, 8) + '...' : '       '} ${l.data}`
    ).join('\n');

    wx.setClipboardData({
      data: text,
      success: () => wx.showToast({ title: `已复制 ${logs.length} 条日志`, icon: 'success' })
    });
  }
});

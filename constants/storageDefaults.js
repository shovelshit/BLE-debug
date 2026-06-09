// constants/storageDefaults.js
// 默认 storage 配置与初始值

// 存储键名常量
const STORAGE_KEYS = {
  QUICK_ACTIONS: 'quick_actions',
  PRESETS: 'presets_global',
  INIT_FLAG: '__storage_inited__',
};

// 统一的默认配置（写入初始化 + 读取兜底共用）
const DEFAULT_CONFIG = {
  [STORAGE_KEYS.QUICK_ACTIONS]: [],
  [STORAGE_KEYS.PRESETS]: [],
};

/**
 * 首次初始化：将默认数据写入 storage（仅执行一次）
 */
function initStorageDefaults() {
  try {
    const inited = wx.getStorageSync(STORAGE_KEYS.INIT_FLAG);
    if (inited) return; // 已初始化过，跳过

    // 写入各默认值
    Object.keys(DEFAULT_CONFIG).forEach((key) => {
      const val = DEFAULT_CONFIG[key];
      // 仅当 storage 中不存在时才写入，避免覆盖用户已有数据
      const existing = wx.getStorageSync(key);
      if (existing === undefined || existing === '') {
        wx.setStorageSync(key, val);
      }
    });

    wx.setStorageSync(STORAGE_KEYS.INIT_FLAG, true);
  } catch (e) {
    console.error('初始化默认 storage 失败', e);
  }
}

/**
 * 从 storage 读取，若不存在则返回默认值
 * @param {string} key
 * @returns {any}
 */
function getWithDefault(key) {
  try {
    const raw = wx.getStorageSync(key);
    return raw !== undefined && raw !== '' ? raw : (DEFAULT_CONFIG[key] ?? undefined);
  } catch (e) {
    return DEFAULT_CONFIG[key] ?? undefined;
  }
}

/**
 * 获取预设值默认值（始终为空数组）
 * @returns {Array}
 */
function getPresetDefault() {
  return [];
}

module.exports = {
  STORAGE_KEYS,
  DEFAULT_CONFIG,
  initStorageDefaults,
  getWithDefault,
  getPresetDefault,
};

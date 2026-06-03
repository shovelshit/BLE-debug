// constants/storageDefaults.js
// 默认 storage 配置与初始值

// 存储键名常量
const STORAGE_KEYS = {
  QUICK_ACTIONS: 'quick_actions',
  INIT_FLAG: '__storage_inited__',
};

// 内置默认数据
const BUILTIN_DEFAULTS = {
  [STORAGE_KEYS.QUICK_ACTIONS]:[],
};

// 预设值 storage 键（全局维度）
const PRESETS_KEY = 'presets_global';


// 各存储项的默认值（读取时兜底）
const DEFAULTS = {
  [STORAGE_KEYS.QUICK_ACTIONS]: [],
  // 预设值按动态键存储，默认值为 []
};

/**
 * 首次初始化：将内置默认数据写入 storage（仅执行一次）
 */
function initStorageDefaults() {
  try {
    const inited = wx.getStorageSync(STORAGE_KEYS.INIT_FLAG);
    if (inited) return; // 已初始化过，跳过

    // 写入各内置默认值
    Object.keys(BUILTIN_DEFAULTS).forEach((key) => {
      const val = BUILTIN_DEFAULTS[key];
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
    return raw !== undefined && raw !== '' ? raw : (DEFAULTS[key] ?? undefined);
  } catch (e) {
    return DEFAULTS[key] ?? undefined;
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
  BUILTIN_DEFAULTS,
  PRESETS_KEY,
  DEFAULTS,
  initStorageDefaults,
  getWithDefault,
  getPresetDefault,
};

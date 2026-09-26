// The only bridge between the page and the system.
const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('aster', {
  getState: () => ipcRenderer.invoke('state:get'),
  onState: (cb) => ipcRenderer.on('state', (_e, s) => cb(s)),
});

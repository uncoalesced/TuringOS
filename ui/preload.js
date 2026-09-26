// The only bridge between the page and the system.
const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('shell', {
  getState: () => ipcRenderer.invoke('state:get'),
  onState: (cb) => ipcRenderer.on('state', (_e, s) => cb(s)),
  listProjects: () => ipcRenderer.invoke('projects:list'),
  startAgent: (project, task) => ipcRenderer.invoke('agent:start', { project, task }),
  launchApp: (id) => ipcRenderer.invoke('dock:launch', id),
  connectGoogle: () => ipcRenderer.invoke('google:connect'),
});

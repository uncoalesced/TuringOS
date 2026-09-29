// The only bridge between the page and the system.
const { contextBridge, ipcRenderer } = require('electron');

contextBridge.exposeInMainWorld('shell', {
  getState: () => ipcRenderer.invoke('state:get'),
  onState: (cb) => ipcRenderer.on('state', (_e, s) => cb(s)),
  listProjects: () => ipcRenderer.invoke('projects:list'),
  startAgent: (project, task, options) => ipcRenderer.invoke('agent:start', { project, task, ...options }),
  launchApp: (id) => ipcRenderer.invoke('dock:launch', id),
  connectGoogle: () => ipcRenderer.invoke('google:connect'),
  askClawd: (message) => ipcRenderer.invoke('clawd:ask', { message }),
  askChat: (message, model, effort) => ipcRenderer.invoke('chat:ask', { message, model, effort }),
});

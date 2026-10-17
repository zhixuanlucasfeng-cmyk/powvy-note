const { contextBridge, ipcRenderer } = require('electron')

contextBridge.exposeInMainWorld('powvy', {
  load: () => ipcRenderer.invoke('notes:load'),
  create: () => ipcRenderer.invoke('notes:create'),
  save: note => ipcRenderer.invoke('notes:save', note),
  remove: note => ipcRenderer.invoke('notes:delete', note),
  close: () => ipcRenderer.send('panel:close'),
  pin: v => ipcRenderer.send('panel:pin', v),
  openExternal: url => ipcRenderer.send('open-external', url),
  onExpanded: fn => ipcRenderer.on('expanded', (_, v) => fn(v)),
})

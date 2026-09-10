local __chunks={}local __loaded={}local function __require(a)if __loaded[a]then return __loaded[a]end local b=assert(__chunks[a],'module not found: '..a)local c=b()__loaded[a]=c return c end __chunks["kernel.blockdev"]=function()local _ENV=setmetatable({require=__require},{__index=_G})local a={}local b={}function a.register(c,d)b[c]=d end function a.get(c)return b[c]end function a.names()local c={}for d in pairs(b)do c[#c+1]=d end return c end function a.file(e)local c,f=fs.open(e,"r+")if not c then return nil,f or("cannot open "..e)end local d=0 local g={kind="file",path=e,handle=c,blockSize=512,read=function(h,j)if h~=d then local k,l=c.seek("set",h)if not k then return nil,tostring(l)end d=h end local i=c.read(j)d=d+#(i or"")return i end,write=function(h,i)if h~=d then local k,m=c.seek("set",h)if not k then return nil,tostring(m)end d=h end local l,j=c.write(i)d=h+#i if l==nil and j~=nil then return nil,j end return true end,getSize=function()return fs.getSize(e)end,close=function()c.close()end,}return g end return a end __chunks["kernel.boot"]=function()local _ENV=setmetatable({require=__require},{__index=_G})local p=require("kernel.scheduler")local d=require("kernel.process")local w=require("kernel.vfs")local c=require("kernel.vfs_api")local h=require("kernel.devdisk")local b=require("kernel.modules")local e1=require("kernel.ext2")local s=require("kernel.tty")local h1=require("kernel.fb")local b1=require("kernel.display")local a1=require("kernel.sysfs")local u=require("kernel.procfs")local g1=require("kernel.pipe")local j=require("kernel.klog")local f1=require("kernel.fstab")local n=require("kernel.init_src")local g=nil local k=nil local x=j.makePri(j.FACILITIES.kern,j.SEVERITIES.info)local y=j.makePri(j.FACILITIES.user,j.SEVERITIES.info)local function d1(l1,...)local j1={}for n1=1,select("#",...)do j1[n1]=tostring(select(n1,...))end local k1=os.epoch("utc")local m1=(k and(k1-k))or 0 local i1=string.format("[%8.3f] %s",m1/1000,table.concat(j1,"\t"))j.write(l1,i1)if g then g.writeLine(i1);g.flush()end write(i1.."\n")end local function a(...)return d1(x,...)end local function v(...)return d1(y,...)end local function z()w.mount("/",w.real(""),{device="rootfs",fstype="ccdisk"})c.mountDev()j.register()u.mount(k,b.version)c.setStdio({read=function(self,...)return read(...)end},{write=function(self,i1)return write(i1)end,writeLine=function(self,i1)return write(i1.."\n")end,flush=function(self)return true end})end local function l()local j1=h.refresh()local i1={}for l1,k1 in ipairs(j1)do i1[#i1+1]=k1.name.."("..k1.fstype..(k1.uuid and(",uuid="..k1.uuid)or"")..")"end a("block devices: "..(#i1>0 and table.concat(i1," ")or"(none)"))p.setDiskHook(function()h.refresh()end)end local function q()local i1="/lib/modules/"..b.version if fs.exists(i1.."/manifest")then return i1 end return nil end local function o()if not c.fs.exists("/etc/passwd")then a("FATAL: /etc/passwd not found on root (no user can log in)")return nil end local i1=require("kernel.user")local j1=i1.init(c.fs)i1.registerSyscalls(j1)a("users loaded: "..table.concat(i1.list(j1),","))return j1 end local function t(i1,j1)if type(i1)~="string"then a("FATAL: "..j1.." init source missing");return end local k1,m1,l1=d.spawn(i1,"init",0)if not k1 then a("FATAL: spawn "..j1.." init failed: "..tostring(l1));return end a("spawned "..j1.." init as pid #"..k1)a("running scheduler (all processes concurrently) ...")p.run()a("kernel: all processes exited, shutting down")if g then g.close();g=nil end end local function e()local i1=b.syscalls()i1["tty.list"]=function()return s.list()end i1["fb.list"]=function()return h1.list()end end local function f()local i1=b.syscalls()i1["proc.wait"]=function(k1)while true do local j1=d.info(k1)if not j1 then return-1 end if j1.status=="dead"or j1.status=="error"then if j1.termSig then return-j1.termSig end return j1.exitCode or 0 end if os.sleep then os.sleep(0.05)end end end i1["proc.info"]=function(j1)return d.info(j1)end i1["proc.onExit"]=function(j1)d.setExitHook(j1)end i1["proc.spawnFile"]=function(l1,p1,x1)local m1=c.fs if not m1.exists(l1)then return nil,l1..": no such file"end if not m1.canExecute(l1)then return nil,l1..": permission denied"end local y1,w1=m1.open(l1,"r")if not y1 then return nil,l1..": "..tostring(w1)end local t1=y1.readAll()y1.close()local k1={}local o1=t1:match("^#!([^\n]*)")local n1=l1 if o1 then local j1,q1=o1:match("^%s*(%S+)%s*(.-)%s*$")if not j1 then return nil,l1..": empty shebang"end if j1:match("[^/]+$")=="env"then local r1=q1:match("^(%S+)")if not r1 then return nil,l1..": shebang env without program"end q1=q1:sub(#r1+1)j1=r1 end if not m1.exists(j1)then return nil,l1..": shebang interpreter not found: "..j1 end if not m1.canExecute(j1)then return nil,l1..": shebang interpreter not executable: "..j1 end local v1=m1.open(j1,"r")if not v1 then return nil,j1..": permission denied"end t1=v1.readAll()v1.close()k1[0]=j1 local u1=1 for b2 in q1:gmatch("%S+")do k1[u1]=b2;u1=u1+1 end k1[u1]=l1;u1=u1+1 for a2=1,#p1 do k1[u1]=p1[a2];u1=u1+1 end n1=j1 else k1[0]=l1 for z1=1,#p1 do k1[z1]=p1[z1]end end local s1=d.current()return d.spawn(t1,n1,s1.pid,nil,nil,k1,x1)end i1["pipe.create"]=function()return g1.create()end i1["stdio.set"]=function(k1,j1)return d.setStdio(k1,j1)end i1["tty.setFocus"]=function(j1)return s.setFocus(j1)end i1["tty.console"]=function()return s.getFocus()end i1["fs.mount"]=function(j1,l1,k1)return h.mount(j1,l1,k1)end i1["fs.umount"]=function(j1)return h.umount(j1)end i1["fs.mounts"]=function()local j1={}for l1,k1 in ipairs(w.list())do j1[#j1+1]={root=k1.root,device=k1.meta and k1.meta.device,fstype=k1.meta and k1.meta.fstype,uuid=k1.meta and k1.meta.uuid,ro=k1.backend.isReadOnly("")and true or false,}end return j1 end i1["fs.fstypes"]=function()return h.fstypes()end i1["blkdev.list"]=function()return h.list()end i1["fstab.entries"]=function(j1)return f1.read(c.fs,j1)end j.registerSyscalls(i1)s.onSignal=function(k1)local j1=d.tcgetpgrp(s.getFocus())if j1 then d.signalGroup(j1,k1)end end end local function i()pcall(term.setCursorBlink,false)local function j1(l1)return string.format("%x",l1)end local k1={id="console",type="console",mode="term",name="term",device=term,getSize=function()return term.getSize()end,text=function(p1,q1,n1,m1,l1)term.setCursorPos(p1+1,q1+1)if m1 and l1 then local o1=#n1 term.blit(n1,string.rep(j1(m1),o1),string.rep(j1(l1),o1))else term.write(n1)end end,blit=function(p1,q1,l1,n1,m1)term.setCursorPos(p1+1,q1+1)local o1=#l1 term.blit(l1,string.rep(j1(n1 or 0),o1),string.rep(j1(m1 or 0),o1))end,fill=function(l1)term.setBackgroundColor(l1 or 0)term.clear()end,flush=function()end,release=function()end,}b1.register(k1)local i1=s.getFocus()c.registerDevice("console",{writable=true,open=function(l1)return s.open(i1,l1)end,})a("console tty registered -> "..i1.." (/dev/console alias)")end local function m(i1,n1)b.log=a if i1 then b.fs=i1 end b.init(n1)local r1,p1=b.loadAll()if not r1 then return nil,p1 end a("modules loaded from "..n1)local q1,k1=b.loadAliases()if q1 then for s1,l1 in ipairs(peripheral.getNames())do local m1=peripheral.getType(l1)if m1 then local o1,j1=b.use(m1,l1)if not o1 and j1 and j1:find("no module for alias")then elseif not o1 then a("autoload "..m1..": "..tostring(j1))end end end elseif k1 and k1:find("no modules.alias")then a("no modules.alias (drivers not auto-loaded)")end return true end local function r(m1)local l1=m1.rootFstype a("root boot: fstype="..tostring(l1).." root="..tostring(m1.rootPath))local j1,i1 if l1=="ext2"then local q1,r1=e1.mount(m1.blockDevice)if not q1 then a("FATAL: root ext2 mount: "..tostring(r1));return end j1=e1.backend(q1)local k1 for t1,s1 in ipairs(h.list())do if s1.type=="part"and s1.img==m1.blockDevice.path then k1=s1;break end end if k1 then i1={device=k1.node,fstype=k1.fstype,uuid=k1.uuid}else a("root boot: no /dev node for root partition, using virtual device")i1={device=m1.rootPath or"rootfs",fstype="ext2"}end elseif l1=="ccdisk"then j1=w.real(m1.rootPath)i1={device=m1.rootPath,fstype="ccdisk"}else a("FATAL: unknown root fstype "..tostring(l1))return end c.mountDev()j.register()u.mount(k,b.version)i()l()w.mount("/",j1,i1)c.setStdio({read=function(self,...)return read(...)end},{write=function(self,u1)return write(u1)end,writeLine=function(self,u1)return write(u1.."\n")end,flush=function(self)return true end})if not o()then return end local n1="/lib/modules/"..b.version if not c.fs.exists(n1.."/manifest")then a("FATAL: root has no module dir "..n1)return end local p1,o1=m(c.fs,n1)if not p1 then a("FATAL: module load failed: "..tostring(o1))return end e()f()a1.mount()t(n,l1)end local c1={}function c1.boot()g=fs.open("/delin.log","a")k=os.epoch("utc")d.log=v a("Delin OS "..b.version.." boot")a("craftos="..os.version())if __boot_info then return r(__boot_info)end local m1,k1=pcall(z)if not m1 then a("FATAL: setupVfs failed: "..tostring(k1))return end a("vfs ready")l()i()if not o()then return end local l1=q()if l1 then local o1,n1=m(nil,l1)if not o1 then a("FATAL: module load failed: "..tostring(n1))return end else a("no module dir found (modules skipped)")end local j1=table.concat(c.devices(),",")local i1={}for p1 in pairs(b.syscalls())do i1[#i1+1]=p1 end a("devices="..j1)a("syscalls="..table.concat(i1,","))e()f()a1.mount()t(n,"")end return c1 end __chunks["kernel.devdisk"]=function()local _ENV=setmetatable({require=__require},{__index=_G})local h=require("kernel.vfs")local e=require("kernel.vfs_api")local j=require("kernel.manifest")local a={}local b={}function a.registerFstype(o,p)b[o]=p end function a.fstypes()local o={}for p in pairs(b)do o[#o+1]=p end table.sort(o)return o end local c={}local d={}local function i(o)local p=""while o>0 do local q=(o-1)%26 p=string.char(97+q)..p o=math.floor((o-1)/26)end return p end local function n()local p={}for r,o in ipairs(peripheral.getNames())do if disk.hasData(o)then local q=disk.getMountPath(o)if not q then error("devdisk: "..o..": disk.hasData but no mount path",0)end p[#p+1]={side=o,mountPath=q,diskId=disk.getID(o),label=disk.getLabel(o),}end end table.sort(p,function(s,t)if s.diskId and t.diskId then if s.diskId~=t.diskId then return s.diskId<t.diskId end elseif s.diskId~=t.diskId then return s.diskId~=nil end return s.side<t.side end)return p end local function f(o)local q=fs.open(o.."/parts/manifest","r")if not q then return nil end local p=q.readAll()q.close()return j.parse(p)end function a.scan()local p={}for w,s in ipairs(n())do local o="sd"..i(w)local q=s.diskId and tostring(s.diskId)or nil p[#p+1]={name=o,node="/dev/"..o,type="disk",fstype="ccdisk",uuid=q,diskId=s.diskId,index=w,side=s.side,label=s.label,mountPath=s.mountPath,size=fs.getCapacity(s.mountPath),}local x=f(s.mountPath)if x then for u,v in ipairs(x.partitions)do local r=v.path if r:sub(1,1)~="/"then r="/"..r end local t=s.mountPath..r p[#p+1]={name=o..u,node="/dev/"..o..u,type="part",fstype=(v.fstype~=""and v.fstype)or"ext2",uuid=q and(q.."-"..u)or nil,diskId=s.diskId,index=w,part=u,role=v.role,side=s.side,img=t,size=fs.exists(t)and fs.getSize(t)or nil,}end end end return p end local function m(r,o)local p,q=fs.open(r.img,(o and o:find("w"))and"r+"or"r")if not p then return nil,q end return{read=function(s,t)return p.read((type(s)=="table")and t or s)end,readLine=function(s)return p.readLine((type(s)=="table")and nil or s)end,readAll=function()return p.readAll()end,write=function(s,t)return p.write((type(s)=="table")and t or s)end,close=function()return p.close()end,}end local function k(o,p)local q=c[o]if not q then return nil,"/dev/"..o..": no such device"end if q.type~="part"then return nil,"/dev/"..o..": CC native filesystem (ccdisk) — mount it, no byte stream"end return m(q,p)end function a.refresh()local q=a.scan()c={}for s,r in ipairs(q)do c[r.name]=r if r.type=="disk"then c["ccdisk"..(r.index-1)]=r end end for p in pairs(d)do if not c[p]then e.unregisterDevice(p)d[p]=nil end end for o in pairs(c)do e.registerDevice(o,{writable=true,open=function(t)return k(o,t)end,})d[o]=true end return q end function a.list()local q=a.refresh()local o={}for u,r in ipairs(h.list())do local p=r.meta and r.meta.device if p then o[p]=o[p]or{}o[p][#o[p]+1]=r.root end end for t,s in ipairs(q)do s.mounted=o[s.node]or{}end return q end function a.find(o)if type(o)~="string"or o==""then return nil,"empty device"end if o:sub(1,5)=="UUID="then local q=o:sub(6)if q==""then return nil,"UUID=: empty uuid"end for t,r in ipairs(a.list())do if r.uuid==q then return r end end return nil,o..": no such device"end a.refresh()local p=o:gsub("^/dev/","")local s=c[p]if not s then return nil,"/dev/"..p..": no such device"end return s end local function l(o)if o.type=="part"then return{img=o.img}end return{ccpath=o.mountPath}end local function g(o,u,s)local p,w,v=h.resolve(o)if not p then return nil,o..": "..tostring(v)end if not p.toReal then return nil,o..": not on a real filesystem"end local t=p.toReal(w)local x=(s=="ccdisk")and{ccpath=t}or{img=t}local r=b[s]if not r then return nil,"unknown fstype: "..s end local z,y,q=pcall(r,x,u)if not z then return nil,o..": "..tostring(y)end if not y then return nil,o..": "..tostring(q)end q=q or{}q.device,q.fstype=o,s h.mount(u,y,q)return true,{device=o,fstype=s}end function a.mountLocal(o,t,s)if not e.fs.exists(o)then return nil,o..": file not found"end local r=s or"ext2"local u={img=o}local q=b[r]if not q then return nil,"unknown fstype: "..r end local w,v,p=pcall(q,u,t)if not w then return nil,o..": "..tostring(v)end if not v then return nil,o..": "..tostring(p)end p=p or{}p.device,p.fstype=o,r h.mount(t,v,p)return true,{device=o,fstype=r}end function a.mount(o,t,u)if not e.fs.isDir(t)then return nil,t..": mount point does not exist"end local s=o:sub(1,5)=="UUID="or o:sub(1,5)=="/dev/"or not o:find("/",1,true)if not s then return g(o,t,u or"ext2")end local v,w=a.find(o)if not v then return nil,w end local q=u or v.fstype if q~=v.fstype then return nil,v.node.." is "..v.fstype..", not "..q end local r=b[q]if not r then return nil,"unknown fstype: "..q.." (module not loaded?)"end local y,x,p=pcall(r,l(v),t)if not y then return nil,v.node..": "..tostring(x)end if not x then return nil,v.node..": "..tostring(p)end p=p or{}p.device,p.fstype,p.uuid=v.node,q,v.uuid h.mount(t,x,p)return true,{device=v.node,fstype=q,uuid=v.uuid}end function a.umount(o)for q,p in ipairs(h.list())do if p.root==o then h.unmount(o)if p.meta and p.meta.cleanup then p.meta.cleanup()end return true end end return nil,o..": not mounted"end return a end __chunks["kernel.display"]=function()local _ENV=setmetatable({require=__require},{__index=_G})local d=require("kernel.vfs_api")local e=require("kernel.tty")local f=require("kernel.fb")local a={}local b={}local c={}function a.register(g)b[g.id]=g local i={}local h,j=e.registerDevice(g)d.registerDevice(h,j)i.tty=h if g.mode~="term"and g.setPixel then local l,k=f.registerDevice(g)d.registerDevice(l,k)i.fb=l end c[g.id]=i return g.id end function a.unregister(i)local h=b[i]if h and h.release then pcall(h.release)end b[i]=nil local g=c[i]if g then if g.tty then d.unregisterDevice(g.tty)end if g.fb then d.unregisterDevice(g.fb)end end c[i]=nil end function a.get(g)return b[g]end function a.list()local g={}for h,i in pairs(b)do g[#g+1]=h end return g end function a.byName(h)for i,g in pairs(b)do if g.name==h then return g end end end function a.resize(h)local g=c[h]if not g then return false end if g.tty then e.resize(g.tty)end if g.fb then f.resize(g.fb)end return true end return a end __chunks["kernel.ext2"]=function()local _ENV=setmetatable({require=__require},{__index=_G})local a={}local y=nil pcall(function()y=require("kernel.process")end)local function x()if not y then return{uid=0,gid=0}end return y.current()end local function j(l1,n1,o1,m1)if n1==0 then return true end local p1=(n1==l1.uid)and 6 or((o1==l1.gid)and 3 or 0)local q1=math.floor(l1.perms/(2^p1))%8 return q1%(m1*2)>=m1 end local function c1(l1)local m1=l1%512 return(m1%2)==1 or(math.floor(m1/8)%2)==1 or(math.floor(m1/64)%2)==1 end local function o(o1,l1)local m1,n1=o1:byte(l1+1,l1+2);return m1+n1*256 end local function i(q1,l1)local m1,n1,o1,p1=q1:byte(l1+1,l1+4);return m1+n1*256+o1*65536+p1*16777216 end local function q(l1)return string.char(l1%256,math.floor(l1/256)%256)end local function t(l1)return string.char(l1%256,math.floor(l1/256)%256,math.floor(l1/65536)%256,math.floor(l1/16777216)%256)end local function f(m1,l1,n1)return m1:sub(1,l1)..q(n1)..m1:sub(l1+3)end local function d(m1,l1,n1)return m1:sub(1,l1)..t(n1)..m1:sub(l1+5)end local function c(m1,l1)return m1.bd.read(l1*m1.blockSize,m1.blockSize)end local function b(n1,l1,m1)return n1.bd.write(l1*n1.blockSize,m1)end local e,p,u=0x4000,0x8000,0xA000 local h1,r,i1,g1,f1,d1,e1,j1=1,2,7,3,4,5,6,0 local function w(l1)return math.floor(l1/0x1000)*0x1000 end local function k1(l1)return l1%0x1000 end local function z(l1)if l1==e then return r end if l1==p then return h1 end if l1==u then return i1 end if l1==0x2000 then return g1 end if l1==0x6000 then return f1 end if l1==0x1000 then return d1 end if l1==0xC000 then return e1 end return j1 end local function g(n1,m1)local l1=n1.bd.read(n1.gdtOffset+m1*32,32)return{blockBitmap=i(l1,0),inodeBitmap=i(l1,4),inodeTable=i(l1,8),freeBlocks=o(l1,12),freeInodes=o(l1,14),}end local function l(l1,o1)local m1=math.floor((o1-1)/l1.inodesPerGroup)local n1=(o1-1)%l1.inodesPerGroup local p1=g(l1,m1)return p1.inodeTable*l1.blockSize+n1*l1.inodeSize end local function a1(l1,m1)return l1.bd.read(l(l1,m1),l1.inodeSize)end function a.mount(q1)local m1=q1.read(1024,1024)if not m1 or#m1<1024 then return nil,"cannot read superblock"end if o(m1,56)~=0xEF53 then return nil,"not EXT2"end local o1=i(m1,24)local l1=1024*2^o1 local n1=i(m1,0)local p1={bd=q1,blockSize=l1,inodes=n1,blocks=i(m1,4),rBlocks=i(m1,8),firstDataBlock=i(m1,20),inodesPerGroup=i(m1,40),blocksPerGroup=i(m1,32),inodeSize=o(m1,88)or 128,firstIno=i(m1,84),gdtOffset=(l1==1024)and(2*l1)or(1*l1),}p1.numGroups=math.max(math.ceil((p1.blocks-p1.firstDataBlock)/p1.blocksPerGroup),math.ceil(n1/p1.inodesPerGroup))return p1 end function a.readInode(n1,p1)local q1=math.floor((p1-1)/n1.inodesPerGroup)local r1=(p1-1)%n1.inodesPerGroup local s1=g(n1,q1)local m1=s1.inodeTable*n1.blockSize+r1*n1.inodeSize local l1=n1.bd.read(m1,n1.inodeSize)if not l1 then return nil end local o1={ino=p1,mode=o(l1,0),uid=o(l1,2),sizeLo=i(l1,4),gid=o(l1,24),links=o(l1,26),blocks=i(l1,28),sizeHigh=i(l1,108),}o1.size=o1.sizeHigh*4294967296+o1.sizeLo o1.type=w(o1.mode)o1.perms=k1(o1.mode)o1.mtime=i(l1,16)o1.ptrs={}for t1=0,14 do o1.ptrs[t1+1]=i(l1,40+t1*4)end return o1 end function a.writeInode(o1,m1)local l1=string.rep("\0",o1.inodeSize)l1=f(l1,0,m1.mode)l1=f(l1,2,m1.uid or 0)local n1=m1.size or 0 l1=d(l1,4,n1%4294967296)l1=d(l1,8,m1.atime or 0)l1=d(l1,12,m1.ctime or 0)l1=d(l1,16,m1.mtime or 0)l1=f(l1,24,m1.gid or 0)l1=f(l1,26,m1.links or 1)l1=d(l1,28,m1.blocks or 0)for p1=1,15 do l1=d(l1,40+(p1-1)*4,m1.ptrs[p1]or 0)end l1=d(l1,108,math.floor(n1/4294967296))return o1.bd.write(l(o1,m1.ino),l1)end local function s(l1)return i(l1.bd.read(1024,1024),12)end local function h(p1,r1,m1,n1,o1)local q1=p1.bd.read(1024,p1.blockSize)q1=d(q1,12,(i(q1,12)or 0)+m1)q1=d(q1,16,(i(q1,16)or 0)+n1)p1.bd.write(1024,q1)local l1=p1.bd.read(p1.gdtOffset+r1*32,32)l1=f(l1,12,(o(l1,12)or 0)+m1)l1=f(l1,14,(o(l1,14)or 0)+n1)if o1 and o1~=0 then l1=f(l1,16,(o(l1,16)or 0)+o1)end p1.bd.write(p1.gdtOffset+r1*32,l1)end function a.allocBlock(m1)if s(m1)<=m1.rBlocks then return nil end local s1=m1.blocksPerGroup local u1=m1.firstDataBlock for n1=0,m1.numGroups-1 do local v1=g(m1,n1)if v1.freeBlocks>0 then local l1=c(m1,v1.blockBitmap)local p1=u1+n1*s1 local q1=math.min(s1,m1.blocks-p1)-1 for o1=0,q1 do local w1=l1:byte(math.floor(o1/8)+1)or 0 if math.floor(w1/2^(o1%8))%2==0 then local t1=math.floor(o1/8)+1 l1=l1:sub(1,t1-1)..string.char(w1+2^(o1%8))..l1:sub(t1+1)b(m1,v1.blockBitmap,l1)h(m1,n1,-1,0)local r1=p1+o1 b(m1,r1,string.rep("\0",m1.blockSize))return r1 end end end end return nil end function a.freeBlock(m1,q1)if q1<m1.firstDataBlock then return end local r1=q1-m1.firstDataBlock local n1=math.floor(r1/m1.blocksPerGroup)local o1=r1%m1.blocksPerGroup local s1=g(m1,n1)local l1=c(m1,s1.blockBitmap)local p1=math.floor(o1/8)+1 local t1=l1:byte(p1)or 0 if math.floor(t1/2^(o1%8))%2==1 then t1=t1-2^(o1%8)l1=l1:sub(1,p1-1)..string.char(t1)..l1:sub(p1+1)b(m1,s1.blockBitmap,l1)h(m1,n1,1,0)end end function a.allocInode(o1,q1,x1,w1)local t1=o1.inodesPerGroup for m1=0,o1.numGroups-1 do local v1=g(o1,m1)if v1.freeInodes>0 then local l1=c(o1,v1.inodeBitmap)for n1=(o1.firstIno-1),(t1-1)do local y1=l1:byte(math.floor(n1/8)+1)or 0 if math.floor(y1/2^(n1%8))%2==0 then local u1=math.floor(n1/8)+1 l1=l1:sub(1,u1-1)..string.char(y1+2^(n1%8))..l1:sub(u1+1)b(o1,v1.inodeBitmap,l1)local s1=m1*t1+n1+1 local r1=math.floor(os.epoch("utc")/1000)local p1={ino=s1,mode=q1,uid=x1 or 0,gid=w1 or 0,links=1,size=0,blocks=0,atime=r1,ctime=r1,mtime=r1,ptrs={}}for z1=1,15 do p1.ptrs[z1]=0 end a.writeInode(o1,p1)h(o1,m1,0,-1,w(q1)==e and 1 or 0)return s1 end end end end return nil end function a.freeInode(m1,o1)local n1=math.floor((o1-1)/m1.inodesPerGroup)local q1=(o1-1)%m1.inodesPerGroup local t1=g(m1,n1)local l1=c(m1,t1.inodeBitmap)local r1=math.floor(q1/8)+1 local u1=l1:byte(r1)or 0 if math.floor(u1/2^(q1%8))%2==1 then local p1=a.readInode(m1,o1)local s1=p1 and p1.type==e u1=u1-2^(q1%8)l1=l1:sub(1,r1-1)..string.char(u1)..l1:sub(r1+1)b(m1,t1.inodeBitmap,l1)h(m1,n1,0,1,s1 and-1 or 0)m1.bd.write(l(m1,o1),string.rep("\0",m1.inodeSize))end end local function m(l1)return math.floor(l1.blockSize/4)end function a.getBlock(p1,m1,l1)local n1=m(p1)if l1<12 then return m1.ptrs[l1+1]end l1=l1-12 if l1<n1 then if m1.ptrs[13]==0 then return 0 end return i(c(p1,m1.ptrs[13]),l1*4)end l1=l1-n1 if l1<n1*n1 then if m1.ptrs[14]==0 then return 0 end local o1=c(p1,m1.ptrs[14])local q1=i(o1,math.floor(l1/n1)*4)if q1==0 then return 0 end return i(c(p1,q1),(l1%n1)*4)end return 0 end local function n(m1,l1)l1.blocks=l1.blocks+math.floor(m1.blockSize/512)end function a.ensureBlock(m1,l1,n1)local r1=m(m1)if n1<12 then if l1.ptrs[n1+1]==0 then l1.ptrs[n1+1]=a.allocBlock(m1)if l1.ptrs[n1+1]then n(m1,l1)end end return l1.ptrs[n1+1]end n1=n1-12 if n1<r1 then if l1.ptrs[13]==0 then l1.ptrs[13]=a.allocBlock(m1);if not l1.ptrs[13]then return nil end n(m1,l1);b(m1,l1.ptrs[13],string.rep("\0",m1.blockSize))end local s1=c(m1,l1.ptrs[13])local t1=i(s1,n1*4)if t1==0 then t1=a.allocBlock(m1);if not t1 then return nil end s1=d(s1,n1*4,t1);b(m1,l1.ptrs[13],s1);n(m1,l1)end return t1 end n1=n1-r1 if n1<r1*r1 then if l1.ptrs[14]==0 then l1.ptrs[14]=a.allocBlock(m1);if not l1.ptrs[14]then return nil end n(m1,l1);b(m1,l1.ptrs[14],string.rep("\0",m1.blockSize))end local p1=c(m1,l1.ptrs[14])local v1=math.floor(n1/r1)*4 local q1=i(p1,v1)if q1==0 then q1=a.allocBlock(m1);if not q1 then return nil end p1=d(p1,v1,q1);b(m1,l1.ptrs[14],p1);n(m1,l1)b(m1,q1,string.rep("\0",m1.blockSize))end local o1=c(m1,q1)local w1=(n1%r1)*4 local u1=i(o1,w1)if u1==0 then u1=a.allocBlock(m1);if not u1 then return nil end o1=d(o1,w1,u1);b(m1,q1,o1);n(m1,l1)end return u1 end return nil end function a.freeBlocksOfInode(m1,l1)local n1=math.ceil((l1.size or 0)/m1.blockSize)for r1=0,n1-1 do local o1=a.getBlock(m1,l1,r1)if o1 and o1~=0 then a.freeBlock(m1,o1)end end local s1=m(m1)if l1.ptrs[13]~=0 then a.freeBlock(m1,l1.ptrs[13])end if l1.ptrs[14]~=0 then local p1=c(m1,l1.ptrs[14])for t1=0,s1-1 do local q1=i(p1,t1*4);if q1~=0 then a.freeBlock(m1,q1)end end a.freeBlock(m1,l1.ptrs[14])end end function a.readDir(v1,p1)local o1={}if p1.type~=e then return nil end local u1=math.ceil((p1.size or 0)/v1.blockSize)for w1=0,u1-1 do local l1=a.getBlock(v1,p1,w1)if not l1 or l1==0 then break end local n1=c(v1,l1)local m1=0 while m1<#n1 do local r1=i(n1,m1)local s1=o(n1,m1+4)if s1==0 then break end local q1=n1:byte(m1+7)local t1=n1:byte(m1+8)if r1~=0 and q1>0 then o1[#o1+1]={ino=r1,name=n1:sub(m1+9,m1+8+q1),fileType=t1}end m1=m1+s1 end end return o1 end local function v(l1)return l1+((4-(l1%4))%4)end local function k(o1,m1,n1)local l1=a.readDir(o1,m1)if not l1 then return nil end for q1,p1 in ipairs(l1)do if p1.name==n1 then return p1 end end return nil end function a.lookup(o1,m1)m1=m1:gsub("^/+",""):gsub("/+$","")local l1=a.readInode(o1,2)if m1==""then return l1 end for n1 in m1:gmatch("[^/]+")do if n1=="."then elseif n1==".."then if l1.type==e then local p1=k(o1,l1,"..")if p1 then l1=a.readInode(o1,p1.ino)end end else if l1.type~=e then return nil end local q1=k(o1,l1,n1)if not q1 then return nil end l1=a.readInode(o1,q1.ino)end end return l1 end local function b1(o1,l1)local n1=l1.size if n1<=60 then local p1=a1(o1,l1.ino)return p1:sub(41,40+n1)end local m1=a.getBlock(o1,l1,0)if not m1 or m1==0 then return nil end return c(o1,m1):sub(1,n1)end function a.readFile(r1,n1)if n1.type==u then return b1(r1,n1)end if n1.type~=p then return nil end local q1={}local l1=n1.size local p1=0 while l1>0 do local m1=a.getBlock(r1,n1,p1)if not m1 or m1==0 then break end local o1=c(r1,m1)if not o1 then break end q1[#q1+1]=o1:sub(1,math.min(#o1,l1))l1=l1-#o1 p1=p1+1 end return table.concat(q1)end function a.addDirEntry(t1,n1,z1,r1,s1)local o1=#z1 local g2=v(8+o1)local x1=math.ceil((n1.size or 0)/t1.blockSize)for h2=0,x1-1 do local p1=a.getBlock(t1,n1,h2)if p1 then local m1=c(t1,p1)local q1=0 while q1<#m1 do local l1=o(m1,q1+4)if l1==0 then break end if i(m1,q1)==0 then if l1>=g2 then local e2=t(r1)..q(l1)..string.char(o1,s1)..z1..string.rep("\0",l1-(8+o1))m1=m1:sub(1,q1)..e2..m1:sub(q1+l1+1)b(t1,p1,m1)return true end else local y1=m1:byte(q1+7)local w1=v(8+y1)local v1=l1-w1 if v1>=g2 then m1=f(m1,q1+4,w1)local a2=q1+w1 local d2=t(r1)..q(v1)..string.char(o1,s1)..z1..string.rep("\0",v1-(8+o1))m1=m1:sub(1,a2)..d2..m1:sub(a2+v1+1)b(t1,p1,m1)return true end end q1=q1+l1 end end end local u1=x1 if not a.ensureBlock(t1,n1,u1)then return nil,"no block"end local b2=a.getBlock(t1,n1,u1)if n1.size==0 then n1.size=t1.blockSize end local c2=n1.size if c2<=u1*t1.blockSize then n1.size=(u1+1)*t1.blockSize end a.writeInode(t1,n1)local f2=t(r1)..q(t1.blockSize)..string.char(o1,s1)..z1..string.rep("\0",t1.blockSize-(8+o1))b(t1,b2,f2)return true end function a.create(n1,q1,t1,o1,v1,s1)local m1=a.lookup(n1,q1)if not m1 or m1.type~=e then return nil,"parent not a dir"end if k(n1,m1,t1)then return nil,"exists"end local z1=x()v1=v1 or z1.uid s1=s1 or z1.gid local p1=a.allocInode(n1,o1,v1,s1)if not p1 then return nil,"alloc inode failed"end local l1=a.readInode(n1,p1)local u1=math.floor(os.epoch("utc")/1000)l1.mtime=u1;l1.ctime=u1;l1.atime=u1 if w(o1)==e then local r1=a.allocBlock(n1)if not r1 then return nil,"no block for dir"end l1.ptrs[1]=r1 l1.size=n1.blockSize l1.blocks=l1.blocks+math.floor(n1.blockSize/512)l1.links=2 local x1=t(p1)..q(12)..string.char(1,r).."."..string.rep("\0",3)local y1=t(m1.ino)..q(n1.blockSize-12)..string.char(2,r)..".."..string.rep("\0",2)b(n1,r1,x1..y1)end a.writeInode(n1,l1)a.addDirEntry(n1,m1,t1,p1,z(w(o1)))if w(o1)==e then local w1=a.readInode(n1,m1.ino)w1.links=w1.links+1 a.writeInode(n1,w1)end return p1 end function a.writeFile(p1,v1,o1)local l1=a.readInode(p1,v1)if not l1 or(l1.type~=p and l1.type~=u)then return nil,"not a regular file"end local m1=p1.blockSize local q1=math.ceil((l1.size or 0)/m1)local n1=math.ceil(#o1/m1)for y1=0,n1-1 do local t1=a.ensureBlock(p1,l1,y1)if not t1 then return nil,"no block"end local u1=y1*m1+1 local s1=o1:sub(u1,u1+m1-1)b(p1,t1,s1)end local w1=m(p1)for x1=n1,q1-1 do local r1=a.getBlock(p1,l1,x1)if r1 and r1~=0 then a.freeBlock(p1,r1)if x1<12 then l1.ptrs[x1+1]=0 end l1.blocks=math.max(0,l1.blocks-math.floor(m1/512))end end if n1<=12 and l1.ptrs[13]~=0 then a.freeBlock(p1,l1.ptrs[13]);l1.ptrs[13]=0 l1.blocks=math.max(0,l1.blocks-math.floor(m1/512))end if n1<=12+w1 and l1.ptrs[14]~=0 then a.freeBlock(p1,l1.ptrs[14]);l1.ptrs[14]=0 l1.blocks=math.max(0,l1.blocks-math.floor(m1/512))end l1.size=#o1 l1.mtime=math.floor(os.epoch("utc")/1000)a.writeInode(p1,l1)return true end function a.appendFile(q1,w1,p1)if p1==""then return true end local m1=a.readInode(q1,w1)if not m1 or(m1.type~=p and m1.type~=u)then return nil,"not a regular file"end local l1=q1.blockSize local n1=m1.size or 0 local u1=1 while u1<=#p1 do local v1=math.floor(n1/l1)local r1=a.ensureBlock(q1,m1,v1)if not r1 then return nil,"no block"end local s1=n1%l1 local o1=p1:sub(u1,u1+(l1-s1)-1)if s1==0 and#o1==l1 then b(q1,r1,o1)else local t1=c(q1,r1)or""b(q1,r1,t1:sub(1,s1)..o1..t1:sub(s1+#o1+1))end n1=n1+#o1 u1=u1+#o1 end m1.size=n1 m1.mtime=math.floor(os.epoch("utc")/1000)a.writeInode(q1,m1)return true end function a.removeDirEntry(v1,s1,u1)local t1=math.ceil((s1.size or 0)/v1.blockSize)for w1=0,t1-1 do local m1=a.getBlock(v1,s1,w1)if m1 then local n1=c(v1,m1)local q1,p1,r1=0,nil,0 while q1<#n1 do local l1=o(n1,q1+4)if l1==0 then break end local o1=n1:byte(q1+7)if o1==#u1 and n1:sub(q1+9,q1+8+o1)==u1 then if not p1 then return nil,"cannot remove first dir entry"end n1=f(n1,p1+4,r1+l1)b(v1,m1,n1)return true end p1,r1=q1,l1 q1=q1+l1 end end end return false end function a.delete(n1,p1,q1)local m1=a.lookup(n1,p1)if not m1 or m1.type~=e then return nil,"parent not a dir"end local o1=k(n1,m1,q1)if not o1 then return nil,"no such entry"end local t1,s1=a.removeDirEntry(n1,m1,q1)if not t1 then return nil,s1 end local l1=a.readInode(n1,o1.ino)if l1 then l1.links=math.max(0,l1.links-1)local r1=(l1.type==e)and(l1.links<=1)or(l1.links<=0)if r1 then a.freeBlocksOfInode(n1,l1)a.freeInode(n1,l1.ino)else a.writeInode(n1,l1)end if l1.type==e then m1.links=math.max(2,m1.links-1)a.writeInode(n1,m1)end end return true end function a.chmod(o1,m1,n1)local l1=a.lookup(o1,m1)if not l1 then return nil,"no such file: "..tostring(m1)end l1.mode=l1.type+(n1%0x1000)a.writeInode(o1,l1)return true end function a.chown(p1,o1,n1,m1)local l1=a.lookup(p1,o1)if not l1 then return nil,"no such file"end if n1 then l1.uid=n1 end if m1 then l1.gid=m1 end a.writeInode(p1,l1)return true end function a.backend(l1)local function m1(n1)return{size=n1.size,isDir=n1.type==e,isReadOnly=false,mode=n1.mode,uid=n1.uid,gid=n1.gid,ino=n1.ino,links=n1.links,mtime=n1.mtime,kind=n1.type==e and"dir"or(n1.type==p and"file"or(n1.type==u and"symlink"or"device")),}end return{kind="virtual",isReadOnly=function()return false end,list=function(p1)local n1=a.lookup(l1,p1 or"/")if not n1 or n1.type~=e then return nil end local r1=x()if not j(n1,r1.uid,r1.gid,4)then return nil,"permission denied"end local o1={}for s1,q1 in ipairs(a.readDir(l1,n1))do if q1.name~="."and q1.name~=".."then o1[#o1+1]=q1.name end end return o1 end,exists=function(n1)return a.lookup(l1,n1)~=nil end,isDir=function(n1)local o1=a.lookup(l1,n1);return o1 and o1.type==e or false end,isFile=function(n1)local o1=a.lookup(l1,n1);return o1 and o1.type==p or false end,attributes=function(n1)local o1=a.lookup(l1,n1);return o1 and m1(o1)or nil end,getSize=function(n1)local o1=a.lookup(l1,n1);return o1 and o1.size or 0 end,getDrive=function()return"ext2"end,getFreeSpace=function()return math.max(0,s(l1)-l1.rBlocks)*l1.blockSize end,getCapacity=function()return l1.blocks*l1.blockSize end,open=function(s1,t1)local w1=a.lookup(l1,s1)local z1=x()local function q1(h2)local g2=a.lookup(l1,h2)if g2 and not(j(g2,z1.uid,z1.gid,2)and j(g2,z1.uid,z1.gid,1))then return false end return true end if t1 and t1:find("w")then if not w1 then local y1=s1:match("^(.*)/[^/]*$")or"/"local b2=s1:match("([^/]*)$")or s1 if not q1(y1)then return nil,"permission denied (dir)"end local d2,e2=a.create(l1,y1,b2,0x81A4)if not d2 then return nil,e2 end w1=a.readInode(l1,d2)end if w1.type==e then return nil,"is a directory"end if not j(w1,z1.uid,z1.gid,2)then return nil,"permission denied (file)"end a.writeFile(l1,w1.ino,"")local r1={}local function u1()return a.writeFile(l1,w1.ino,table.concat(r1))end return{write=function(self,g2)if g2==nil then g2=self end;r1[#r1+1]=g2;return#g2 end,writeLine=function(self,g2)if g2==nil then g2=self end;r1[#r1+1]=g2.."\n";return#g2+1 end,flush=u1,close=u1,seek=function()return 0 end,}end if t1 and t1:find("a")then if not w1 then local x1=s1:match("^(.*)/[^/]*$")or"/"local a2=s1:match("([^/]*)$")or s1 if not q1(x1)then return nil,"permission denied (dir)"end local c2,f2=a.create(l1,x1,a2,0x81A4)if not c2 then return nil,f2 end w1=a.readInode(l1,c2)end if w1.type==e then return nil,"is a directory"end if not j(w1,z1.uid,z1.gid,2)then return nil,"permission denied (file)"end local p1={}local function v1()if#p1==0 then return true end local g2=table.concat(p1)p1={}return a.appendFile(l1,w1.ino,g2)end return{write=function(self,g2)if g2==nil then g2=self end;p1[#p1+1]=g2;return#g2 end,writeLine=function(self,g2)if g2==nil then g2=self end;p1[#p1+1]=g2.."\n";return#g2+1 end,flush=v1,close=v1,seek=function()return 0 end,}end if not w1 then return nil,"no such file"end if w1.type==e then return nil,"is a directory"end if not j(w1,z1.uid,z1.gid,4)then return nil,"permission denied (read)"end local n1=a.readFile(l1,w1)local o1=0 return{readAll=function()o1=#n1;return n1 end,read=function(h2,i2)local g2 if type(h2)=="number"then g2=h2 elseif type(h2)=="table"and type(i2)=="number"then g2=i2 end if g2==nil then local k2=n1:sub(o1+1);o1=#n1;return k2 end local j2=n1:sub(o1+1,o1+g2)o1=o1+#j2 return j2 end,readLine=function()if o1>=#n1 then return nil end local g2=n1:find("\n",o1+1,true)if g2 then local h2=n1:sub(o1+1,g2-1)o1=g2 return h2 end local i2=n1:sub(o1+1)o1=#n1 return i2 end,write=function()end,writeLine=function()end,close=function()end,flush=function()return true end,seek=function()return 0 end,}end,makeDir=function(p1)local o1=p1:match("^(.*)/[^/]*$")or"/"local q1=p1:match("([^/]*)$")or p1 local n1=a.lookup(l1,o1)local t1=x()if n1 and not(j(n1,t1.uid,t1.gid,2)and j(n1,t1.uid,t1.gid,1))then error("permission denied",2)end local s1,r1=a.create(l1,o1,q1,0x41ED)if not s1 then error(tostring(r1),2)end return true end,delete=function(p1)local o1=p1:match("^(.*)/[^/]*$")or"/"local q1=p1:match("([^/]*)$")or p1 local n1=a.lookup(l1,o1)local s1=x()if n1 and not(j(n1,s1.uid,s1.gid,2)and j(n1,s1.uid,s1.gid,1))then error("permission denied",2)end local t1,r1=a.delete(l1,o1,q1)if not t1 then error(tostring(r1),2)end return true end,chmod=function(o1,n1)return a.chmod(l1,o1,n1)end,chown=function(o1,p1,n1)return a.chown(l1,o1,p1,n1)end,canExecute=function(o1)local n1=a.lookup(l1,o1)if not n1 then return false end if n1.type~=p and n1.type~=u then return false end local p1=x()if p1.uid==0 then return c1(n1.perms)end return j(n1,p1.uid,p1.gid,1)end,}end function a.mkfs(i2,g2)g2=g2 or{}local l1=1024 local o1=tonumber(g2.blocks)if not o1 then return nil,"mkfs: 必须给 blocks"end o1=math.floor(o1)if o1<64 then return nil,"mkfs: 块数至少 64(64KB)"end if o1>8192 then return nil,"mkfs: 只支持单块组(最多 8192 块 = 8MB)"end local t1,n1,q1=128,256,8192 local r1=1 local d2=11 local u1,v1,x1=3,4,5 local w1=math.ceil(n1*t1/l1)local p1=x1+w1 if o1<p1+2 then return nil,string.format("mkfs: 块数至少 %d(元数据 %d 块 + 根目录 + lost+found)",p1+2,p1)end local l2=i2.getSize and i2.getSize()or nil if l2 and l2>0 and l2<o1*l1 then return nil,string.format("mkfs: 设备只有 %d 字节, 放不下 %d 块(%d 字节)",l2,o1,o1*l1)end local f2=math.floor(g2.time or(os.epoch and(os.epoch("utc")/1000))or os.time())local r2=64*1024 local m2=string.rep("\0",math.min(r2,o1*l1))local h2=0 while h2<o1*l1 do local f3=math.min(#m2,o1*l1-h2)local g3,w2=i2.write(h2,f3==#m2 and m2 or m2:sub(1,f3))if not g3 then return nil,string.format("mkfs: 清零失败于偏移 %d: %s",h2,tostring(w2))end h2=h2+f3 end local m1=string.rep("\0",1024)m1=d(m1,0,n1)m1=d(m1,4,o1)m1=d(m1,8,0)m1=d(m1,12,o1-p1-1)m1=d(m1,16,n1-10)m1=d(m1,20,r1)m1=d(m1,24,0)m1=d(m1,28,0)m1=d(m1,32,q1)m1=d(m1,36,q1)m1=d(m1,40,n1)m1=d(m1,44,f2)m1=d(m1,48,f2)m1=f(m1,52,0)m1=f(m1,54,0xFFFF)m1=f(m1,56,0xEF53)m1=f(m1,58,1)m1=f(m1,60,1)m1=f(m1,62,0)m1=d(m1,64,f2)m1=d(m1,68,0)m1=d(m1,72,0)m1=d(m1,76,1)m1=f(m1,80,0)m1=f(m1,82,0)m1=d(m1,84,d2)m1=f(m1,88,t1)m1=f(m1,90,0)m1=d(m1,92,0)m1=d(m1,96,0x2)m1=d(m1,100,0)local n2=f2%2147483647 local q2={}for h3=1,16 do n2=(n2*1103515245+12345)%2147483648 q2[h3]=string.char(math.floor(n2/8388608)%256)end m1=m1:sub(1,104)..table.concat(q2)..m1:sub(121)local o2=tostring(g2.label or"delin"):sub(1,15)m1=m1:sub(1,120)..o2..string.rep("\0",16-#o2)..m1:sub(137)if not i2.write(1024,m1)then return nil,"mkfs: 写超级块失败"end local z1=p1 local j2=o1-z1-1 local b3=t(u1)..t(v1)..t(x1)..q(j2)..q(n1-10)..q(1)..q(0)..string.rep("\0",12)if not i2.write(2*l1,b3)then return nil,"mkfs: 写块组描述符失败"end local function y1(l3,k3)local j3=math.floor(k3/8)+1 local m3=l3:byte(j3)or 0 return l3:sub(1,j3-1)..string.char(m3+2^(k3%8))..l3:sub(j3+1)end local s1=l1*8 local c2=string.rep("\0",l1)for x2=0,z1-1 do c2=y1(c2,x2)end for a3=o1-1,s1-1 do c2=y1(c2,a3)end if not i2.write(u1*l1,c2)then return nil,"mkfs: 写块位图失败"end local e2=string.rep("\0",l1)for y2=0,9 do e2=y1(e2,y2)end for z2=n1,s1-1 do e2=y1(e2,z2)end if not i2.write(v1*l1,e2)then return nil,"mkfs: 写 inode 位图失败"end local t2={bd=i2,blockSize=l1,inodes=n1,blocks=o1,rBlocks=0,firstDataBlock=r1,inodesPerGroup=n1,blocksPerGroup=q1,inodeSize=t1,firstIno=d2,gdtOffset=2*l1,numGroups=1,}local a2=p1 local c3=t(2)..q(12)..string.char(1,r).."."..string.rep("\0",3)local d3=t(2)..q(l1-12)..string.char(2,r)..".."..string.rep("\0",2)if not b(t2,a2,c3..d3)then return nil,"mkfs: 写根目录失败"end local b2={ino=2,mode=e+493,uid=0,gid=0,links=2,size=l1,blocks=math.floor(l1/512),atime=f2,ctime=f2,mtime=f2,ptrs={a2},}for i3=2,15 do b2.ptrs[i3]=0 end if not a.writeInode(t2,b2)then return nil,"mkfs: 写根 inode 失败"end local e3,u2=a.create(t2,"/","lost+found",e+448)if not e3 then return nil,"mkfs: 建 lost+found 失败: "..tostring(u2)end local p2,v2=a.mount(i2)if not p2 then return nil,"mkfs: 自检挂载失败: "..tostring(v2)end local k2=a.lookup(p2,"/")if not k2 or k2.type~=e then return nil,"mkfs: 自检读不到根目录"end local s2=a.lookup(p2,"/lost+found")if not s2 or s2.type~=e then return nil,"mkfs: 自检读不到 /lost+found"end if k2.links~=3 then return nil,"mkfs: 根目录 links 应为 3, 实得 "..tostring(k2.links)end return p2 end return a end __chunks["kernel.fb"]=function()local _ENV=setmetatable({require=__require},{__index=_G})local i={}local b=0 local c={}local a=0x000000 local function f(k,n,m,l)return k*16777216+n*65536+m*256+l end local function e(k)local l=math.floor(k/16777216)%256 local o=math.floor(k/65536)%256 local n=math.floor(k/256)%256 local m=k%256 return string.char(l,o,n,m)end local function d(k,l,m)if not k.hasDirty then k.dirtyX0,k.dirtyY0,k.dirtyX1,k.dirtyY1=l,m,l,m k.hasDirty=true else if l<k.dirtyX0 then k.dirtyX0=l end if m<k.dirtyY0 then k.dirtyY0=m end if l>k.dirtyX1 then k.dirtyX1=l end if m>k.dirtyY1 then k.dirtyY1=m end end end local function j(k)local o,n=k.getSize()o=math.floor(o)n=math.floor(n)local q=o*n local m={}for p=1,q do m[p]=a end local l={dev=k,w=o,h=n,px=m,pos=0,hasDirty=false,dirtyX0,dirtyY0,dirtyX1,dirtyY1=0,0,0,0,closed=false,}return l end local function h(k)if k.closed or not k.hasDirty then return true end local l,n=k.dirtyX0,k.dirtyY0 local m,o=k.dirtyX1,k.dirtyY1 k.hasDirty=false for r=n,o do for q=l,m do local p=k.px[r*k.w+q+1]if p~=a then k.dev.setPixel(q,r,p)end end end k.dev.flush()return true end local function g(k,l)return{write=function(self,m)if k.closed then return nil,"device closed"end if type(m)~="string"then return nil,"expected string"end local o=1 local n=math.floor(#m/4)for v=0,n-1 do local r,u,t,s=m:byte(o,o+3)local q=k.pos%k.w local p=math.floor(k.pos/k.w)if p<k.h then k.px[p*k.w+q+1]=f(r,u,t,s)d(k,q,p)end k.pos=(k.pos+1)%(k.w*k.h)o=o+4 end return#m end,read=function(self,o)if k.closed then return nil,"device closed"end o=o or(k.w*k.h*4)local m=math.floor(o/4)local n={}for q=0,m-1 do local p=(k.pos+q)%(k.w*k.h)local r=p%k.w local s=math.floor(p/k.w)n[#n+1]=e(k.px[s*k.w+r+1])end k.pos=(k.pos+m)%(k.w*k.h)return table.concat(n)end,seek=function(self,m)local n=m or 0 k.pos=math.floor(n/4)%(k.w*k.h)return k.pos end,clear=function(self,m)if k.closed then return nil,"device closed"end for n=0,k.w-1 do for o=0,k.h-1 do k.px[o*k.w+n+1]=m end end k.hasDirty=true k.dirtyX0,k.dirtyY0,k.dirtyX1,k.dirtyY1=0,0,k.w-1,k.h-1 return true end,setPixel=function(self,n,o,m)if k.closed then return nil,"device closed"end n,o=math.floor(n or 0),math.floor(o or 0)if n<0 or o<0 or n>=k.w or o>=k.h then return nil,"out of range"end k.px[o*k.w+n+1]=m d(k,n,o)return true end,getSize=function()return k.w,k.h end,getBpp=function()return 32 end,getPixel=function(self,m,n)if m<0 or n<0 or m>=k.w or n>=k.h then return nil end return k.px[n*k.w+m+1]end,flush=function(self)if k.closed then return nil,"device closed"end return h(k)end,close=function(self)k.closed=true return true end,}end function i.registerDevice(n)local m="fb"..b b=b+1 local l=j(n)c[m]=l local k={writable=true,open=function(o)return g(l,o)end,getCtx=function()return l end,}return m,k end function i.get(k)return c[k]end function i.list()local k={}for l in pairs(c)do k[#k+1]=l end return k end function i.resize(n)local k=c[n]if not k then return end local p,q=k.dev.getSize()p=math.floor(p)q=math.floor(q)local m,o=k.w,k.h local l={}for s=0,q-1 do for r=0,p-1 do if r<m and s<o then l[s*p+r+1]=k.px[s*m+r+1]else l[s*p+r+1]=a end end end k.px=l k.w,k.h=p,q k.pos=0 k.hasDirty=true k.dirtyX0,k.dirtyY0,k.dirtyX1,k.dirtyY1=0,0,p-1,q-1 return true end return i end __chunks["kernel.fstab"]=function()local _ENV=setmetatable({require=__require},{__index=_G})local a={}local b={defaults=true,noauto=true,nofail=true,auto=true,ro="ignored",rw="ignored",user="ignored",users="ignored",}function a.parse(i,e)e=e or"/etc/fstab"local d={}local c=0 for q in(i.."\n"):gmatch("([^\n]*)\n")do c=c+1 local l=q:gsub("#.*$",""):gsub("^%s+",""):gsub("%s+$","")if l~=""then local n={}for r in l:gmatch("%S+")do n[#n+1]=r end if#n<3 then return nil,string.format("%s:%d: need at least <device> <mountpoint> <fstype>",e,c)end local g=n[4]or"defaults"local m={}for f in(g..","):gmatch("([^,]*),")do f=f:gsub("^%s+",""):gsub("%s+$","")if f~=""then local o=b[f]if not o then return nil,string.format("%s:%d: unknown mount option '%s'",e,c,f)end m[f]=true end end local function p(u,s)if u==nil then return 0 end local t=tonumber(u)if not t or t<0 or t~=math.floor(t)then return nil,string.format("%s:%d: bad %s field '%s'",e,c,s,u)end return t end local j,k=p(n[5],"dump")if not j then return nil,k end local h h,k=p(n[6],"pass")if not h then return nil,k end d[#d+1]={device=n[1],mountpoint=n[2],fstype=n[3],options=g,opts=m,dump=j,pass=h,line=c,}end end return d end function a.read(e,c)c=c or"/etc/fstab"if not e.exists(c)then return{}end local l,i=e.open(c,"r")if not l then return nil,c..": "..tostring(i)end local f=l.readAll()l.close()local d,j=a.parse(f,c)if not d then return nil,j end for m,k in ipairs(d)do local g,h=a.escapeMount(k.mountpoint)if not g then return nil,string.format("%s:%d: %s",c,k.line,h)end k.unit=g..".mount"end return d end function a.escapeMount(c)if c=="/"then return"-"end local d=c:gsub("^/+",""):gsub("/+$","")if d==""then return nil,"empty mount point"end d=d:gsub("/","-")if d:find("[^A-Za-z0-9_.%-]")then return nil,"mount point has characters not representable in a unit name: "..c end return d end return a end __chunks["kernel.klog"]=function()local _ENV=setmetatable({require=__require},{__index=_G})local q=require("kernel.vfs_api")local a={}local e={kern=0,user=1,mail=2,daemon=3,auth=4,syslog=5,lpr=6,news=7,uucp=8,cron=9,authpriv=10,ftp=11,local0=16,local1=17,local2=18,local3=19,local4=20,local5=21,local6=22,local7=23,}local f={emerg=0,alert=1,crit=2,err=3,warning=4,notice=5,info=6,debug=7,}local i,j={},{}for w,y in pairs(e)do i[y]=w end for x,z in pairs(f)do j[z]=x end a.FACILITIES=e a.SEVERITIES=f function a.split(a1)return math.floor(a1/8),a1%8 end function a.makePri(a1,b1)return a1*8+b1 end function a.facilityName(a1)return i[a1]or("fac"..a1)end function a.severityName(a1)return j[a1]or("sev"..a1)end local r=16384 local o=os.epoch("utc")local n={}local c=1 local g=1 local h=0 local k=0 function a.write(d1,a1)a1=tostring(a1 or"")local c1=(os.epoch("utc")-o)*1000 for b1 in(a1.."\n"):gmatch("([^\n]*)\n")do n[g]={seq=g,usec=c1,pri=d1,text=b1}h=h+#b1+1 g=g+1 end while h>r and c<g do local e1=n[c]h=h-(#e1.text+1)n[c]=nil c=c+1 k=k+1 end end function a.kern(a1)a.write(a.makePri(e.kern,f.info),a1)end function a.user(a1)a.write(a.makePri(e.user,f.info),a1)end function a.stats()return{first=c,next=g,bytes=h,drops=k,boot=o}end local function m(a1)return string.format("%d,%d,%d,-;%s",a1.pri,a1.seq,a1.usec,a1.text)end local function s()local a1=c local b1=false local c1={readAvailable=function()if b1 then return""end local d1={}while a1<g do local e1=n[a1]a1=a1+1 if e1 then d1[#d1+1]=m(e1)end end return table.concat(d1,"\n")..(#d1>0 and"\n"or"")end,readLine=function()while not b1 do if a1<g then local d1=n[a1]a1=a1+1 if d1 then return m(d1)end else os.sleep(0.05)end end return nil end,cursor=function()return a1 end,seek=function(e1,f1)local d1=(type(e1)=="table")and f1 or e1 d1=tonumber(d1)if not d1 then return nil,"seek: bad sequence number"end a1=math.max(math.floor(d1),c)return true end,close=function()b1=true;return true end,flush=function()return true end,getDeviceName=function()return"kmsg"end,}return c1 end local t=8192 local b={}local d=0 local l=0 local function p(a1)b[#b+1]=a1 d=d+#a1+1 while d>t and#b>1 do local b1=table.remove(b,1)d=d-(#b1+1)l=l+1 end end local function v()local a1=""local b1=false return{write=function(f1,e1)if b1 then return nil,"log closed"end e1=tostring(e1 or"")a1=a1..e1 while true do local d1=a1:find("\n",1,true)if not d1 then break end local c1=a1:sub(1,d1-1)a1=a1:sub(d1+1)if c1~=""then p(c1)end end return#e1 end,writeLine=function(self,c1)return self:write(tostring(c1 or"").."\n")end,flush=function()return true end,close=function()if not b1 and a1~=""then p(a1);a1=""end b1=true return true end,getDeviceName=function()return"log"end,}end local function u()local a1=false return{readAvailable=function()if a1 or#b==0 then return""end local b1=table.concat(b,"\n").."\n"b,d={},0 return b1 end,readLine=function()while not a1 do if#b>0 then local b1=table.remove(b,1)d=d-(#b1+1)return b1 end os.sleep(0.05)end return nil end,close=function()a1=true;return true end,flush=function()return true end,getDeviceName=function()return"log"end,}end function a.logDrops()return l end function a.register()q.registerDevice("kmsg",{writable=false,open=function(a1)if a1 and a1:find("[wa+]")then return nil,"/dev/kmsg: read-only"end return s()end,})q.registerDevice("log",{writable=true,open=function(a1)if a1 and a1:find("r")then return u()end return v()end,})end function a.registerSyscalls(a1)a1["syslog.facility"]=function(b1)return e[(b1 or""):lower()]end a1["syslog.severity"]=function(b1)return f[(b1 or""):lower()]end a1["syslog.facilityName"]=function(b1)return a.facilityName(b1)end a1["syslog.severityName"]=function(b1)return a.severityName(b1)end a1["syslog.facilities"]=function()local b1={}for c1 in pairs(e)do b1[#b1+1]=c1 end table.sort(b1)return b1 end a1["syslog.severities"]=function()local b1={}for c1 in pairs(f)do b1[#b1+1]=c1 end table.sort(b1)return b1 end a1["klog.stats"]=function()return a.stats()end a1["klog.logDrops"]=function()return a.logDrops()end end return a end __chunks["kernel.manifest"]=function()local _ENV=setmetatable({require=__require},{__index=_G})local a={}function a.parse(f)local d,b={},nil for c in f:gmatch("[^\r\n]+")do c=c:match("^%s*(.-)%s*$")if c~=""and c:sub(1,1)~="#"then local e,h,g=c:match("^(%S+)%s+(%S+)%s*(%S*)%s*$")if e then if e=="boot"then b=h else d[#d+1]={role=e,path=h,fstype=g or""}end end end end return{partitions=d,boot=b}end function a.findRoot(c)for d,b in ipairs(c.partitions)do if b.role=="root"then return b end end return nil end return a end __chunks["kernel.modules"]=function()local _ENV=setmetatable({require=__require},{__index=_G})local i=require("kernel.vfs_api")local p=require("kernel.vfs")local g=require("kernel.display")local m=require("kernel.devdisk")local l=require("kernel.sysfs")local n=require("kernel.version")local a={}a.version=n a.log=print a.fs=fs local e={}local c={}local function o(q)return(q:match("^%s*(.-)%s*$"))end local function j(v)local q={name=nil,version=nil,deps={},author=nil,description=nil}for u in v:gmatch("[^\r\n]+")do local s=u:match("^%s*(.-)%s*$")if s==""then elseif s:sub(1,1)~="-"then break else local r,t=u:match("^%s*%-%-@([%w_]+)%s+(.-)%s*$")if r then if r=="name"then q.name=t elseif r=="version"then q.version=t elseif r=="author"then q.author=t elseif r=="description"then q.description=t elseif r=="deps"then for w in t:gmatch("[^,%s]+")do q.deps[#q.deps+1]=w end end end end end if not q.name then q.name="unnamed"end return q end local function h(q)local r=a.fs.open(q,"r")if not r then return nil end local s=r.readAll()r.close()return s end local function k(q)return{name=q,version=a.version,log=a.log,registerSyscall=function(s,r)c[s]=r end,registerDevice=function(s,r)i.registerDevice(s,r)end,unregisterDevice=function(r)i.unregisterDevice(r)end,registerFS=function(t,r,s)p.mount(t,r,s)end,registerFstype=function(r,s)m.registerFstype(r,s)end,registerDisplay=function(r)return g.register(r)end,unregisterDisplay=function(r)g.unregister(r)end,displayList=function()return g.list()end,registerSysfsClass=function(r,s)l.registerClass(r,s)end,unregisterSysfsClass=function(r)l.unregisterClass(r)end,}end local b=nil function a.init(q)b=q end local function d(q,x)if e[q]and e[q].state=="active"then return true end if not b then return nil,"module manager not initialized"end local y=h(b.."/"..q..".ko")if not y then return nil,"module file not found: "..q end local r=j(y)for h1,a1 in ipairs(r.deps)do local f1,d1=d(a1)if not f1 then return nil,"dep '"..a1.."' failed: "..tostring(d1)end end local c1=setmetatable({require=require},{__index=_G})local t,v=load(y,q,"t",c1)if not t then return nil,"load failed: "..tostring(v)end local z,s=pcall(t)if not z then return nil,"module body error: "..tostring(s)end if type(s)~="table"then return nil,"module must return a table: "..q end local u={name=q,meta=r,mod=s,deps=r.deps,ref=0,state="loading"}if s.init then local e1,b1=pcall(s.init,k(q),x)if not e1 then u.state="error";e[q]=u return nil,"init error: "..tostring(b1)end end u.state="active";e[q]=u for g1,w in ipairs(r.deps)do if e[w]then e[w].ref=e[w].ref+1 end end a.log(string.format("[module] loaded '%s' v%s (deps:%s)",q,r.version or"?",table.concat(r.deps,",")))return true end function a.load(q)return d(q)end local f={}function a.loadAliases()if not b then return nil,"module manager not initialized"end local t=h(b.."/modules.alias")if not t then return nil,"no modules.alias at "..b end f={}for q in t:gmatch("[^\r\n]+")do q=q:gsub("%s*#.*$",""):gsub("^%s*",""):gsub("%s*$","")if q~=""then local r,s=q:match("^(%S+)%s+(%S+)$")if r and s then f[r]=s end end end return true end function a.use(r,s)local q=f[r]if not q then return nil,"no module for alias '"..tostring(r).."' (see modules.alias)"end return d(q,s)end function a.loadAll()if not b then return nil,"module manager not initialized"end local q=h(b.."/manifest")if not q then return nil,"no manifest at "..b.."/manifest"end local s={}for r in q:gmatch("[^\r\n]+")do r=o(r)if r~=""then s[#s+1]=r end end for w,t in ipairs(s)do local v,u=d(t)if not v then return nil,u end end return true end function a.unload(q)local r=e[q]if not r then return nil,"not loaded: "..q end if r.ref>0 then return nil,"module in use (refcount="..r.ref.."): "..q end if r.mod and r.mod.exit then local u,t=pcall(r.mod.exit)if not u then a.log("module exit error "..q..": "..tostring(t))end end for v,s in ipairs(r.deps)do if e[s]then e[s].ref=math.max(0,e[s].ref-1)end end r.state="unloaded";e[q]=nil a.log("[module] unloaded '"..q.."'")return true end function a.reload(q)local s,r=a.unload(q)if not s then return nil,r end return d(q)end function a.syscalls()return c end function a.applyToEnv(q)q.syscalls=c end c["modules.load"]=function(q)return a.load(q)end c["modules.unload"]=function(q)return a.unload(q)end c["modules.reload"]=function(q)return a.reload(q)end c["modules.list"]=function()local q={}for r,s in pairs(e)do q[#q+1]=r..":"..s.state end return q end return a end __chunks["kernel.pipe"]=function()local _ENV=setmetatable({require=__require},{__index=_G})local d={}local e=16384 local function c()return{data="",writers=0,readers=0}end local function a(f)f.writers=f.writers+1 local g=false local h={pipe=true,write=function(n,l)if g then return nil,"pipe closed"end l=tostring(l or"")local k,m=1,#l while k<=m do if f.readers==0 then return nil,"broken pipe"end local j=e-#f.data if j<=0 then os.sleep(0.05)else local i=l:sub(k,k+j-1)f.data=f.data..i k=k+#i end end return m end,flush=function()return true end,close=function()if not g then g=true;f.writers=f.writers-1 end return true end,}return h end local function b(f)f.readers=f.readers+1 local g=false local h h={pipe=true,readLine=function()if g then return nil end while true do local j=f.data:find("\n",1,true)if j then local i=f.data:sub(1,j-1)f.data=f.data:sub(j+1)return i end if f.writers==0 then if#f.data>0 then local k=f.data;f.data="";return k end return nil end os.sleep(0.05)end end,read=function(l,i)if g then return nil end if i==nil or i=="*l"then return h.readLine()end if i=="a"then return h.readAll()end local k=tonumber(i)or 0 if k<=0 then return""end while#f.data==0 do if f.writers==0 then return nil end os.sleep(0.05)end local j=f.data:sub(1,k)f.data=f.data:sub(k+1)return j end,readAll=function()if g then return nil end local i={}while true do if#f.data>0 then i[#i+1]=f.data;f.data=""end if f.writers==0 then break end os.sleep(0.05)end local j=table.concat(i)return j~=""and j or nil end,close=function()if not g then g=true;f.readers=f.readers-1 end return true end,}return h end function d.create()local f=c()return b(f),a(f)end return d end __chunks["kernel.procenv"]=function()local _ENV=setmetatable({require=__require},{__index=_G})local a={}local d={"colors","colours","keys","vector","textutils","parallel","term","write","read","printError","sleep","window","paintutils","redstone","rednet","gps","http","turtle","_HOST","_CC_DEFAULT_SETTINGS",}local b={"assert","collectgarbage","error","getmetatable","ipairs","load","loadstring","next","pairs","pcall","rawequal","rawget","rawlen","rawset","select","setfenv","getfenv","setmetatable","tonumber","tostring","type","unpack","xpcall","_VERSION",}local c={"string","table","math","coroutine"}local e={loadAPI=true,unloadAPI=true,run=true,pullEvent=true,pullEventRaw=true,queueEvent=true,shutdown=true,reboot=true,exit=true,remove=true,rename=true,tmpname=true,getenv=true,}local function f(i)local g={}for j,k in pairs(i)do g[j]=k end local h=getmetatable(i)if type(h)=="table"then setmetatable(g,h)end return g end function a.apply(g)for q,i in ipairs(b)do local n=_G[i]if n~=nil then g[i]=n end end for s,j in ipairs(c)do local o=_G[j]if o~=nil then g[j]=f(o)end end local k={}for m,p in pairs(_G.os)do if not e[m]then k[m]=p end end g.os=k for r,h in ipairs(d)do local l=_G[h]if type(l)=="table"then g[h]=f(l)elseif l~=nil then g[h]=l end end g.debug={traceback=_G.debug.traceback}end return a end __chunks["kernel.process"]=function()local _ENV=setmetatable({require=__require},{__index=_G})local c=require("kernel.signal")local i=require("kernel.scheduler")local s=require("kernel.tty")local l=require("kernel.vfs_api")local k=require("kernel.modules")local q=require("kernel.procenv")local a={}a.next_pid=0 a.log=nil local b={}local d={}local o={}local f={}local e={}local function r(...)if a.log then a.log(...)else print(...)end end local function p()a.next_pid=a.next_pid+1 return a.next_pid end local function n(b1,z,d1,c1,v,w)v=v or{}w=w or{}local y={}for e1=1,#v do y[e1]=v[e1]end local a1=b[z]and b[z].cwd or"/"local u={}local t=b[z]if t and t.envvars then for h1,i1 in pairs(t.envvars)do u[h1]=i1 end end if w.env then for f1,g1 in pairs(w.env)do if g1==nil then u[f1]=nil else u[f1]=tostring(g1)end end end local x={pid=b1,ppid=z,uid=d1 or 0,gid=c1 or 0,cwd=w.cwd or a1 or"/",argv=v,args=y,argc=#y,arg0=v[0]or y[1]or"",env=u,getenv=function(j1)return u[j1]end,print=r,spawn=function(o1,n1,m1,l1,j1,k1)return a.spawn(o1,n1,b1,m1,l1,j1,k1)end,}q.apply(x)l.installForEnv(x)k.applyToEnv(x)x._G=x return x end local function j()return{pending={},handlers={},stopped=false,stopSig=nil,termSig=nil,}end local function m(t,u)if not d[t]then d[t]={}end d[t][u]=true end local function h(v)local u=d[v]if not u then return end if not d[1]then d[1]={}end for t in pairs(u)do local w=b[t]if w then w.ppid=1 end d[1][t]=true end d[v]=nil end function a.spawn(k1,c1,w,h1,g1,b1,z)if z and z.ppid then w=z.ppid end w=w or 0 if type(k1)~="string"then return nil,nil,"spawn expects a source string, got "..type(k1)end local u=b[w]h1=h1 or(u and u.uid)or 0 g1=g1 or(u and u.gid)or 0 b1=b1 or{}local v=p()local j1,d1 if u then j1=u.sid or 0 d1=u.pgrp or u.pid else j1=0 d1=v end local a1=n(v,w,h1,g1,b1,z)local x=b[w]local e1=z and z.stdio if e1 then a1.__stdio.input=e1.input a1.__stdio.output=e1.output else local y=(x and x.stdio)or l.getStdio()if y then a1.__stdio.input=y.input a1.__stdio.output=y.output end end local f1,i1=load(k1,c1 or("proc#"..v),"t",a1)if not f1 then return nil,nil,"load failed: "..tostring(i1)end local l1=coroutine.create(f1)o[l1]=v local t={pid=v,ppid=w,name=c1 or("proc#"..v),co=l1,status="running",exitCode=nil,termSig=nil,uid=h1,gid=g1,cwd=a1.cwd,argv=b1,envvars=a1.env,stdio=a1.__stdio,pgrp=d1,sid=j1,sig=j(),}t.onExit=function(u1,m1,r1,o1)t.status=m1 t.exitCode=(m1=="dead")and((type(o1)=="number")and o1 or 0)or nil if t.stdio then local q1,p1=t.stdio.output,t.stdio.input if q1 and q1.pipe and q1.close then pcall(q1.close)end if p1 and p1.pipe and p1.close then pcall(p1.close)end end if m1=="error"then t.error=r1 if a.log then pcall(a.log,"[proc "..v.." "..tostring(c1).."] ERROR: "..tostring(r1))end end if t.sid==v then local n1=f[t.sid]if n1 then if n1.ctty and e[n1.ctty]==n1.sid then e[n1.ctty]=nil end f[t.sid]=nil end end h(v)if a.onExit then local t1,s1=pcall(a.onExit,v,m1,t.exitCode,t.termSig)if not t1 and a.log then a.log("[proc exit hook] "..tostring(s1))end end end b[v]=t m(w,v)i.addProcess({pid=v,co=l1,name=t.name,started=false,filter=nil,dead=false,status="running",onExit=t.onExit,sig=t.sig,canonical=t,})return v,t,nil end function a.info(t)return b[t]end function a.list()local t={}for v,u in pairs(b)do if u.status=="running"or u.status=="stopped"then t[#t+1]=u end end table.sort(t,function(w,x)return w.pid<x.pid end)return t end function a.ttyFor(u)local v=b[u]if not v then return nil end local t=f[v.sid]if not t then return nil end return t.ctty end function a.fgPgrpFor(u)local v=b[u]if not v then return nil end local t=f[v.sid]if not t then return nil end return t.fgPgrp end function a.setExitHook(t)a.onExit=t end function a.current()local u=coroutine.running()local t=u and o[u]if not t then return{pid=0,uid=0,gid=0}end local v=b[t]if not v then return{pid=0,uid=0,gid=0}end return{pid=t,uid=v.uid,gid=v.gid}end function a.currentGroup()local t=a.current()local u=b[t.pid]if not u then return nil,nil end return u.pgrp,u.sid end function a.setStdio(u,t)local v=a.current()local w=b[v.pid]if not w or not w.stdio then return false end w.stdio.input=u w.stdio.output=t return true end function a.kill(u,v)local w=b[u]if not w then return nil,"no such process: "..tostring(u)end local t=a.current()if t.uid~=0 and t.uid~=w.uid then return nil,"permission denied"end w.sig.pending[v]=true return true end function a.signalGroup(u,w)local t=b[u]if not t then return nil,"no such process group: "..tostring(u)end local v=a.current()if v.uid~=0 and v.uid~=t.uid then return nil,"permission denied"end local x=0 for z,y in pairs(b)do if y.pgrp==u then y.sig.pending[w]=true x=x+1 end end if x==0 then return nil,"no such process group"end return x end function a.setHandler(t,v)if not c.catchable(t)then return nil,"uncatchable signal: "..c.name(t)end local u=a.current()local w=b[u.pid]if not w then return nil,"no current process"end w.sig.handlers[t]=v return true end function a.setsid()local v=a.current()local u=b[v.pid]if not u then return nil,"no current process"end if u.pgrp==u.pid then return nil,"setsid: already a process group leader"end local t=u.pid u.sid=t u.pgrp=t f[t]={sid=t,leader=u.pid,ctty=nil,fgPgrp=t}return t end function a.setpgid(v,t)local w=b[v]if not w then return nil,"no such process: "..tostring(v)end if w.pid==w.sid then return nil,"setpgid: session leader"end local x=a.current()local u=b[x.pid]if u.sid~=w.sid then return nil,"setpgid: cross-session"end if t==0 or t==nil then t=w.pid end w.pgrp=t return true end function a.tcsetpgrp(t,v)local z=a.current()local w=b[z.pid]local u=e[t]if not u then if not w then return nil,"tcsetpgrp: no current process"end u=w.sid if not u or u==0 then return nil,"tcsetpgrp: no session"end f[u].ctty=t e[t]=u end local y=f[u]if not y then return nil,"tcsetpgrp: no session"end if not v or v==0 then v=z.pid end local x=false for b1,a1 in pairs(b)do if a1.pgrp==v and a1.sid==u then x=true;break end end if not x then return nil,"tcsetpgrp: not a process group in session"end y.fgPgrp=v return true end function a.tcgetpgrp(t)local v=e[t]if not v then return nil end local u=f[v]if not u then return nil end return u.fgPgrp end function a.sessionForTty(t)return e[t]end function a.checkTtyRead(u)local w=a.current()local x=b[w.pid]if not x then return false end local v=e[u]if not v then return false end if x.sid~=v then return false end local t=f[v]if not t or not t.fgPgrp then return false end if x.pgrp==t.fgPgrp then return false end x.sig.pending[c.SIGTTIN]=true return true end s.readGuard=a.checkTtyRead function a.applySignals(y)local u=y.sig if not u then return"run"end local t=u.pending if u.stopped and next(t)==nil then return"stop"end if next(t)==nil then return"run"end local x={}for d1 in pairs(t)do x[#x+1]=d1 end table.sort(x)local v=false for e1,w in ipairs(x)do if v then break end if w==c.SIGCONT then if u.stopped then u.stopped=false u.stopSig=nil if y.canonical then y.canonical.status="running"end end t[w]=nil elseif w==c.SIGKILL then u.termSig=w if y.canonical then y.canonical.termSig=w end v=true t[w]=nil elseif w==c.SIGSTOP then if not u.stopped then u.stopped=true u.stopSig=w if y.canonical then y.canonical.status="stopped"end end t[w]=nil else local c1=u.handlers[w]if c1 then t[w]=nil local b1,a1=pcall(c1,w)if not b1 then u.termSig=w if y.canonical then y.canonical.termSig=w;y.canonical.status="error";y.canonical.error=a1 end v=true end else local z=c.defaultAction(w)if z=="term"then u.termSig=w if y.canonical then y.canonical.termSig=w end v=true t[w]=nil elseif z=="stop"then if not u.stopped then u.stopped=true u.stopSig=w if y.canonical then y.canonical.status="stopped"end end t[w]=nil elseif z=="cont"then t[w]=nil else t[w]=nil end end end end if v then return"dead"end if u.stopped then return"stop"end return"run"end function a.dumpTree()local t={}local function u(y,w)local v=b[y]if not v then return end t[#t+1]=string.rep("  ",w)..string.format("#%d %s (ppid=%d, %s, pgrp=%d, sid=%d, sig=%s)",y,v.name or"?",v.ppid,v.status or"?",v.pgrp or 0,v.sid or 0,v.termSig and c.name(v.termSig)or"-")local x=d[y]if x then for z in pairs(x)do u(z,w+1)end end end u(1,0)return table.concat(t,"\n")end local g=k.syscalls()g["signal.kill"]=function(t,u)return a.kill(t,u)end g["signal.killpg"]=function(t,u)return a.signalGroup(t,u)end g["signal.install"]=function(t,u)return a.setHandler(t,u)end g["signal.list"]=function()return c.listNumbers()end g["signal.name"]=function(t)return c.name(t)end g["signal.number"]=function(t)return c.number(t)end g["sig.name"]=function(t)return c.name(t)end g["sig.list"]=function()return c.listNumbers()end g["sig.number"]=function(t)return c.number(t)end g["job.setsid"]=function()return a.setsid()end g["job.setpgid"]=function(u,t)return a.setpgid(u,t)end g["job.tcsetpgrp"]=function(t,u)return a.tcsetpgrp(t,u)end g["job.tcgetpgrp"]=function(t)return a.tcgetpgrp(t)end g["job.group"]=function()return a.currentGroup()end g["job.sessfor"]=function(t)return a.sessionForTty(t)end i.setSignalCheck(a.applySignals)return a end __chunks["kernel.procfs"]=function()local _ENV=setmetatable({require=__require},{__index=_G})local x=require("kernel.vfs")local b=require("kernel.process")local s={}local r=0 local c="0.0.0"local e={"cmdline","comm","cwd","stat","status"}local f={"mounts","uptime","version"}local function t(y)return(y or""):gsub("^/+","")end local function g(z)local y=z.name or("proc#"..z.pid)return y:match("([^/]+)$")or y end local function m(y)if y.status=="stopped"then return"T","stopped"end if y.pid==b.current().pid then return"R","running"end return"S","sleeping"end local function w(z)local y=b.ttyFor(z.pid)if not y then return"0",-1 end return(y:gsub("^/dev/","")),(b.fgPgrpFor(z.pid)or-1)end local function u(a1)local y=m(a1)local b1,z=w(a1)return string.format("%d (%s) %s %d %d %d %s %d\n",a1.pid,g(a1),y,a1.ppid or 0,a1.pgrp or 0,a1.sid or 0,b1,z)end local function p(z)local y,a1=m(z)return table.concat({"Name:\t"..g(z),"State:\t"..y.." ("..a1..")","Tgid:\t"..z.pid,"Pid:\t"..z.pid,"PPid:\t"..(z.ppid or 0),"Pgrp:\t"..(z.pgrp or 0),"Session:\t"..(z.sid or 0),"Uid:\t"..(z.uid or 0),"Gid:\t"..(z.gid or 0),},"\n").."\n"end local function h(b1)local y=b1.argv or{}if y[0]==nil and#y==0 then return""end local z={}for a1=0,#y do z[#z+1]=tostring(y[a1])end return table.concat(z,"\0").."\0"end local function o()local y={}for d1,a1 in ipairs(x.list())do local b1=(a1.meta and a1.meta.device)or"none"local c1=(a1.meta and a1.meta.fstype)or"none"local z=a1.backend.isReadOnly("")and"ro"or"rw"y[#y+1]=string.format("%s %s %s %s 0 0",b1,a1.root,c1,z)end return table.concat(y,"\n").."\n"end local function q()return string.format("%.2f\n",(os.epoch("utc")-r)/1000)end local function l()return"Delin OS "..c.." ("..tostring(os.version())..", ".._VERSION..")\n"end local function d(a1)a1=t(a1):gsub("/+$","")if a1==""then return"root"end local y={}for e1 in a1:gmatch("[^/]+")do y[#y+1]=e1 end local z=y[1]if z=="self"then local b1=b.current().pid if not b1 or b1==0 then return nil end z=tostring(b1)end if z:match("^%d+$")then local c1=tonumber(z)if#y==1 then return"pid",c1 end if#y==2 then return"pidfile",c1,y[2]end return nil end if#y==1 then for f1,d1 in ipairs(f)do if d1==z then return"sysfile",nil,z end end end return nil end local function a(y)local z=b.info(y)if not z then return nil end if z.status~="running"and z.status~="stopped"then return nil end return z end local function n(z)local y=b.current().uid or 0 return y==0 or y==z.uid end local function j(z,y)if y=="comm"then return g(z).."\n"end if y=="stat"then return u(z)end if y=="status"then return p(z)end if y=="cmdline"then return h(z)end if y=="cwd"then if not n(z)then return nil,"permission denied"end return(z.cwd or"/").."\n"end return nil,"no such file: "..tostring(y)end local function k(y)if y=="uptime"then return q()end if y=="version"then return l()end if y=="mounts"then return o()end return nil,"no such file: "..tostring(y)end local function i(y)local z=1 return{read=function(d1,c1)if z>#y then return nil end if type(c1)~="number"then local b1=y:sub(z)z=#y+1 return b1 end local a1=y:sub(z,z+c1-1)z=z+#a1 return a1 end,readLine=function()if z>#y then return nil end local b1=y:find("\n",z,true)if not b1 then local c1=y:sub(z)z=#y+1 return c1 end local a1=y:sub(z,b1-1)z=b1+1 return a1 end,readAll=function()if z>#y then return nil end local a1=y:sub(z)z=#y+1 return a1 end,write=function()return nil,"read-only fs"end,writeLine=function()return nil,"read-only fs"end,close=function()end,flush=function()return true end,}end local v={kind="virtual",list=function(c1)local z,b1=d(c1)if z=="root"then local y={}for i1,g1 in ipairs(b.list())do y[#y+1]=tostring(g1.pid)end y[#y+1]="self"for h1,e1 in ipairs(f)do y[#y+1]=e1 end return y end if z=="pid"then if not a(b1)then return nil end local a1={}for d1,f1 in ipairs(e)do a1[d1]=f1 end return a1 end return nil end,exists=function(b1)local y,z,a1=d(b1)if y=="root"or y=="sysfile"then return true end if y=="pid"then return a(z)~=nil end if y=="pidfile"then if not a(z)then return false end for d1,c1 in ipairs(e)do if c1==a1 then return true end end return false end return false end,isDir=function(a1)local y,z=d(a1)if y=="root"then return true end if y=="pid"then return a(z)~=nil end return false end,attributes=function(b1)local y,a1,z=d(b1)if y=="root"then return{size=0,isDir=true,isReadOnly=true,name="proc"}end if y=="pid"then if not a(a1)then return nil end return{size=0,isDir=true,isReadOnly=true,name=tostring(a1)}end if y=="pidfile"then if not backend.exists(b1)then return nil end return{size=0,isDir=false,isReadOnly=true,name=z}end if y=="sysfile"then return{size=0,isDir=false,isReadOnly=true,name=z}end return nil end,getSize=function()return 0 end,getDrive=function()return"proc"end,getFreeSpace=function()return 0 end,getCapacity=function()return 0 end,isReadOnly=function()return true end,open=function(d1,b1)local z,e1,c1=d(d1)if z=="root"or z=="pid"then return nil,"is a directory"end if not z then return nil,"no such path: /proc/"..t(d1)end if b1 and b1:find("w")then return nil,"read-only fs: /proc/"..t(d1)end local y,a1 if z=="pidfile"then local f1=a(e1)if not f1 then return nil,"no such process: "..tostring(e1)end y,a1=j(f1,c1)else y,a1=k(c1)end if y==nil then return nil,a1 end return i(y)end,makeDir=function()error("read-only fs",2)end,move=function()error("read-only fs",2)end,copy=function()error("read-only fs",2)end,delete=function()error("read-only fs",2)end,}function s.mount(z,y)r=z or os.epoch("utc")c=y or c x.mount("/proc",v,{device="proc",fstype="proc"})return true end return s end __chunks["kernel.scheduler"]=function()local _ENV=setmetatable({require=__require},{__index=_G})local f=require("kernel.tty")local a={}local b={}local c=nil function a.setSignalCheck(g)c=g end local d=nil function a.setDiskHook(g)d=g end function a.addProcess(g)b[#b+1]=g end local function e(g)if g[1]=="char"or g[1]=="paste"then f.feedInput(g)elseif g[1]=="key"or g[1]=="key_up"then f.routeKey(g)elseif(g[1]=="disk"or g[1]=="disk_eject")and d then d(g)end end function a.run()local j={n=0}local l=os.startTimer(0.5)local m=os.startTimer(0.05)local n=false local h=false while#b>0 do local p=1 n=false h=false while p<=#b do local g=b[p]if not n then n=true if j[1]=="timer"then if j[2]==l then f.blinkTick()l=os.startTimer(0.5)h=true elseif j[2]==m then m=os.startTimer(0.05)h=true end end e(j)end local o="run"if c then o=c(g)end if o=="dead"then g.status="dead";g.dead=true if g.onExit then g.onExit(g,"dead",nil)end table.remove(b,p)elseif o=="stop"then p=p+1 else local i if not g.started or j[1]=="terminate"then i=true elseif g.filter==nil then i=true elseif g.filter==j[1]then i=not h else i=false end if i then local q,k if not g.started then g.started=true q,k=coroutine.resume(g.co)else q,k=coroutine.resume(g.co,table.unpack(j,1,j.n))end if not q then g.status="error";g.error=k;g.dead=true if g.onExit then g.onExit(g,"error",k)end table.remove(b,p)elseif coroutine.status(g.co)=="dead"then g.status="dead";g.dead=true if g.onExit then g.onExit(g,"dead",nil,k)end table.remove(b,p)else g.filter=k p=p+1 end else p=p+1 end end end if#b>0 then j=table.pack(os.pullEventRaw())end end end return a end __chunks["kernel.signal"]=function()local _ENV=setmetatable({require=__require},{__index=_G})local a={}a.SIGHUP=1 a.SIGINT=2 a.SIGQUIT=3 a.SIGKILL=9 a.SIGUSR1=10 a.SIGUSR2=12 a.SIGPIPE=13 a.SIGALRM=14 a.SIGTERM=15 a.SIGCHLD=17 a.SIGCONT=18 a.SIGSTOP=19 a.SIGTSTP=20 a.SIGTTIN=21 a.SIGTTOU=22 local e={[a.SIGHUP]="HUP",[a.SIGINT]="INT",[a.SIGQUIT]="QUIT",[a.SIGKILL]="KILL",[a.SIGUSR1]="USR1",[a.SIGUSR2]="USR2",[a.SIGPIPE]="PIPE",[a.SIGALRM]="ALRM",[a.SIGTERM]="TERM",[a.SIGCHLD]="CHLD",[a.SIGCONT]="CONT",[a.SIGSTOP]="STOP",[a.SIGTSTP]="TSTP",[a.SIGTTIN]="TTIN",[a.SIGTTOU]="TTOU",}local c={}local b={}for h,g in ipairs({a.SIGHUP,a.SIGINT,a.SIGQUIT,a.SIGKILL,a.SIGUSR1,a.SIGUSR2,a.SIGPIPE,a.SIGALRM,a.SIGTERM,a.SIGCHLD,a.SIGCONT,a.SIGSTOP,a.SIGTSTP,a.SIGTTIN,a.SIGTTOU})do c[#c+1]=g b[#b+1]=e[g]end local f={[a.SIGHUP]="term",[a.SIGINT]="term",[a.SIGQUIT]="term",[a.SIGKILL]="term",[a.SIGUSR1]="term",[a.SIGUSR2]="term",[a.SIGPIPE]="term",[a.SIGALRM]="term",[a.SIGTERM]="term",[a.SIGCHLD]="ign",[a.SIGCONT]="cont",[a.SIGSTOP]="stop",[a.SIGTSTP]="stop",[a.SIGTTIN]="stop",[a.SIGTTOU]="stop",}local d={[a.SIGKILL]=true,[a.SIGSTOP]=true}function a.name(i)return e[i]or("SIG"..tostring(i))end function a.number(j)local i=(j or""):upper()i=i:gsub("^SIG","")for l,k in pairs(e)do if k==i then return l end end return nil end function a.defaultAction(i)return f[i]or"term"end function a.catchable(i)return not d[i]end function a.listNumbers()return c end function a.listNames()return b end return a end __chunks["kernel.sysfs"]=function()local _ENV=setmetatable({require=__require},{__index=_G})local n=require("kernel.vfs")local c=require("kernel.display")local i={}local f="class"local a={}function i.registerClass(o,p)a[o]=p end function i.unregisterClass(o)a[o]=nil end local function m(o)return(o or""):gsub("^/+","")end local function g(p)p=m(p)if p==""then return"root"end local o={}for q in p:gmatch("[^/]+")do o[#o+1]=q end if o[1]~=f then return nil end if#o==1 then return"class"end if#o==2 then return"classdir",o[2]end if#o==3 then return"entry",o[2],o[3]end if#o==4 then return"attr",o[2],o[3],o[4]end return nil end local function b(q,o)local p=a[q]if not p then return false end for s,r in ipairs(p.list())do if r==o then return true end end return false end local function d(q,p,s)local r=a[q]if not r or not b(q,p)then return false end local o=r.attrs(p)if not o then return false end for u,t in ipairs(o)do if t==s then return true end end return false end local function e(r,o,q)local p=a[r]if not p or not p.set then return false end if not d(r,o,q)then return false end if p.writable then return p.writable(o,q)and true or false end return true end local function k(t,r,s)local u=a[t]local p=0 local function o()return u.get(r,s)or""end local function q(x)if not e(t,r,s)then return nil,"read-only attribute"end local y=x:gsub("[\r\n]+$","")local w,v=u.set(r,s,y)if w then return#x else return nil,v end end return{read=function(y,x)local w=o()if p>=#w then return nil end if type(x)~="number"then p=#w;return w end local v=w:sub(p+1,p+x)p=p+#v return v end,readLine=function()if p>=#o()then return nil end p=#o()return o()end,readAll=function()if p>=#o()then return nil end p=#o()return o()end,write=function(self,v)return q(v)end,writeLine=function(self,v)return q(v.."\n")end,close=function()end,flush=function()return true end,}end local l={kind="virtual",list=function(t)local o,r,p=g(t)if o=="root"then return{f}end if o=="class"then local q={}for u in pairs(a)do q[#q+1]=u end table.sort(q)return q end if o=="classdir"then local s=a[r]if not s then return nil end return s.list()end if o=="entry"then if not b(r,p)then return nil end return a[r].attrs(p)end return nil end,exists=function(s)local o,q,p,r=g(s)if o=="root"or o=="class"then return true end if o=="classdir"then return a[q]~=nil end if o=="entry"then return b(q,p)end if o=="attr"then return d(q,p,r)end return false end,isDir=function(r)local o,q,p=g(r)if o=="root"or o=="class"then return true end if o=="classdir"then return a[q]~=nil end if o=="entry"then return b(q,p)end return false end,attributes=function(s)local p,q,o,r=g(s)if p=="root"then return{size=0,isDir=true,isReadOnly=true,name="sys"}end if p=="class"then return{size=0,isDir=true,isReadOnly=true,name=f}end if p=="classdir"then if not a[q]then return nil end return{size=0,isDir=true,isReadOnly=true,name=q}end if p==nil then return nil end if p=="entry"then if not b(q,o)then return nil end return{size=0,isDir=true,isReadOnly=true,name=o}end if not d(q,o,r)then return nil end return{size=0,isDir=false,isReadOnly=not e(q,o,r),name=r}end,getSize=function()return 0 end,getDrive=function()return"sys"end,getFreeSpace=function()return 0 end,getCapacity=function()return 0 end,isReadOnly=function(s)local q,r,o,p=g(s)if q~="attr"then return true end return not e(r,o,p)end,open=function(t,s)local r,q,o,p=g(t)if r~="attr"then if r then return nil,"is a directory"end return nil,"no such path: /sys/"..m(t)end if not d(q,o,p)then return nil,"no such attribute: "..q.."/"..tostring(o).."/"..tostring(p)end if s and s:find("w")and not e(q,o,p)then return nil,"read-only attribute: "..p end return k(q,o,p)end,makeDir=function()error("read-only fs",2)end,move=function()error("read-only fs",2)end,copy=function()error("read-only fs",2)end,delete=function()error("read-only fs",2)end,}local function j(p)local q=c.byName(p)if not q then return nil end local o={"name","type","size"}if q.listConfig then for s,r in ipairs(q.listConfig())do o[#o+1]=r end end return o end local function h(p,o)if o=="name"or o=="type"or o=="size"then return false end local q=c.byName(p)if not(q and q.listConfig and q.setConfig)then return false end for s,r in ipairs(q.listConfig())do if r==o then return true end end return false end i.registerClass("display",{list=function()local o={}for r,q in ipairs(c.list())do local p=c.get(q)if p and p.name then o[#o+1]=p.name end end return o end,attrs=j,writable=h,get=function(p,o)local q=c.byName(p)if not q then return nil end if o=="name"then return q.name or q.id end if o=="type"then return tostring(q.type or"")end if o=="size"then local s,r=q.getSize()return tostring(s).."x"..tostring(r)end if q.getConfig then return q.getConfig(o)end return nil end,set=function(o,q,p)local r=c.byName(o)if not r then return nil,"no such display: "..o end local u,t=r.getSize()local x,s=r.setConfig(q,p)if x then local w,v=r.getSize()if u~=w or t~=v then c.resize(r.id)end return true end return nil,s end,})function i.mount()n.mount("/sys",l,{device="sysfs",fstype="sysfs"})return true end return i end __chunks["kernel.tty"]=function()local _ENV=setmetatable({require=__require},{__index=_G})local l1=require("kernel.signal")local f={}f.onSignal=nil f.readGuard=nil local t=0 local c={}local d=nil local u={[0x0]=0x000000,[0x1]=0xB300B3,[0x2]=0x3344CC,[0x3]=0x66CCCC,[0x4]=0x4CBB4C,[0x5]=0x66CC33,[0x6]=0x7F3300,[0x7]=0xCC3333,[0x8]=0x4C4C4C,[0x9]=0x999999,[0xa]=0xE96699,[0xb]=0xE6E633,[0xc]=0xE69C33,[0xd]=0xE64CE6,[0xe]=0x99CCFF,[0xf]=0xFFFFFF,}local p1={[0x0]=0xf,[0x1]=0xa,[0x2]=0xb,[0x3]=0x9,[0x4]=0xd,[0x5]=0x5,[0x6]=0xc,[0x7]=0xe,[0x8]=0x7,[0x9]=0x8,[0xa]=0x6,[0xb]=0x4,[0xc]=0x1,[0xd]=0x2,[0xe]=0x3,[0xf]=0x0,}local g1={[0xf]=0x1,[0xc]=0x2,[0xd]=0x4,[0xe]=0x8,[0xb]=0x10,[0x5]=0x20,[0xa]=0x40,[0x8]=0x80,[0x9]=0x100,[0x3]=0x200,[0x1]=0x400,[0x2]=0x800,[0x6]=0x1000,[0x4]=0x2000,[0x7]=0x4000,[0x0]=0x8000,}local g,h=0xf,0x0 local l={[1]=0x0,[2]=0x7,[3]=0x4,[4]=0x6,[5]=0x2,[6]=0x1,[7]=0x3,[8]=0x9,[9]=0x8,[10]=0xa,[11]=0x5,[12]=0xb,[13]=0xe,[14]=0xd,[15]=0x3,[16]=0xf,}local v1={[0x0]=0x8,[0x7]=0xa,[0x4]=0x5,[0x6]=0xb,[0x2]=0xe,[0x1]=0xd,[0x3]=0x3,[0x9]=0xf,}local function q1(w1)return w1.bold and(v1[w1.fg]or w1.fg)or w1.fg end local function s1(x1)local c2,b2=x1.getSize()local w1 if x1.mode=="term"then w1={dev=x1,mode="term",cols=math.floor(c2),rows=math.floor(b2),cellW=1,cellH=1}else local a2=x1.cellW local z1=x1.cellH w1={dev=x1,mode="pixel",cols=math.floor(c2/a2),rows=math.floor(b2/z1),cellW=a2,cellH=z1,}end local e2=w1.cols*w1.rows local y1={}for d2=1,e2 do y1[d2]={ch=" ",fg=g,bg=h}end w1.grid=y1 w1.cursorX,w1.cursorY=0,0 w1.fg,w1.bg=g,h w1.dirty={}w1.dirtyList={}w1.closed=false w1.inputBuffer=""w1.lineQueue={}w1.echo=true w1.eof=false w1.intr=false w1.reading=false w1.cursorOn=true w1.cursorHidden=false w1.cursorRenderedIdx=nil w1.escState=nil w1.escParams=""w1.escInter=""w1.bold=false w1.reverse=false w1.saved=nil return w1 end local function p(w1)return w1.cursorOn and not w1.cursorHidden end local function j(w1,x1)if not w1.dirty[x1]then w1.dirty[x1]=true w1.dirtyList[#w1.dirtyList+1]=x1 end end local function m1(w1,x1)return(x1-1)==w1.cursorY*w1.cols+w1.cursorX end local function a(w1)local y1=w1.cursorRenderedIdx local x1=p(w1)and(w1.cursorY*w1.cols+w1.cursorX+1)or nil if y1 then j(w1,y1)end if x1 then j(w1,x1)end w1.cursorRenderedIdx=x1 end local function k1(w1)for y1=0,w1.rows-2 do for x1=0,w1.cols-1 do w1.grid[y1*w1.cols+x1+1]=w1.grid[(y1+1)*w1.cols+x1+1]end end for z1=0,w1.cols-1 do w1.grid[(w1.rows-1)*w1.cols+z1+1]={ch=" ",fg=q1(w1),bg=w1.bg,rev=w1.reverse}end for a2=1,w1.rows*w1.cols do j(w1,a2)end w1.cursorRenderedIdx=nil a(w1)end local function k(w1,x1)if x1=="\n"then w1.cursorY=w1.cursorY+1 w1.cursorX=0 elseif x1=="\r"then w1.cursorX=0 a(w1)return elseif x1=="\b"then if w1.cursorX>0 then w1.cursorX=w1.cursorX-1 end a(w1)return elseif x1=="\t"then w1.cursorX=math.floor(w1.cursorX/8+1)*8 else local y1=w1.cursorY*w1.cols+w1.cursorX+1 if y1<=w1.rows*w1.cols then w1.grid[y1]={ch=x1,fg=q1(w1),bg=w1.bg,rev=w1.reverse}j(w1,y1)end w1.cursorX=w1.cursorX+1 end if w1.cursorY>=w1.rows then if w1.cursorY>w1.rows-1 then w1.cursorY=w1.rows-1 if w1.cursorX>w1.cols-1 then w1.cursorX=w1.cols-1 end k1(w1)end elseif w1.cursorX>=w1.cols then w1.cursorX=0 w1.cursorY=w1.cursorY+1 if w1.cursorY>=w1.rows then w1.cursorY=w1.rows-1 k1(w1)end end a(w1)end local function b(w1)local y1=w1.dev for j2,a2 in ipairs(w1.dirtyList)do local x1=w1.grid[a2]local c2=(a2-1)%w1.cols local e2=math.floor((a2-1)/w1.cols)local b2,z1=x1.fg,x1.bg if x1.rev then b2,z1=z1,b2 end if m1(w1,a2)and p(w1)then b2,z1=z1,b2 end if w1.mode=="term"then y1.text(c2,e2,x1.ch,p1[b2],p1[z1])else local f2=c2*w1.cellW local g2=e2*w1.cellH y1.rect(f2,g2,w1.cellW,w1.cellH,u[z1])local i2=f2 if y1.getTextWidth then local h2=y1.getTextWidth(x1.ch)local d2=math.floor((w1.cellW-h2)/2)if d2>0 then i2=i2+d2 end end y1.text(i2,g2,x1.ch,u[b2],u[z1])end end w1.dirty={}w1.dirtyList={}y1.flush()end local function r(w1)return{ch=" ",fg=g,bg=w1.bg}end local function m(w1)for x1=1,w1.rows*w1.cols do w1.grid[x1]=r(w1)end if w1.mode=="term"then w1.dev.fill(g1[w1.bg])else w1.dev.fill(u[w1.bg])end w1.dev.flush()w1.dirty={}w1.dirtyList={}w1.cursorRenderedIdx=nil end local function w(w1)w1.saved={x=w1.cursorX,y=w1.cursorY,fg=w1.fg,bg=w1.bg,bold=w1.bold,reverse=w1.reverse,}end local function q(w1)local x1=w1.saved if not x1 then return end w1.cursorX,w1.cursorY=x1.x,x1.y w1.fg,w1.bg,w1.bold,w1.reverse=x1.fg,x1.bg,x1.bold,x1.reverse a(w1)end local function e(w1,x1,y1)w1.cursorX=math.max(0,math.min(w1.cols-1,x1))w1.cursorY=math.max(0,math.min(w1.rows-1,y1))a(w1)end local function y(w1,y1)local c2=w1.rows*w1.cols if y1==2 then m(w1)a(w1)b(w1)return end local z1=w1.cursorY*w1.cols+w1.cursorX+1 local x1,a2=z1,c2 if y1==1 then x1,a2=1,z1 end for b2=x1,a2 do w1.grid[b2]=r(w1)j(w1,b2)end a(w1)end local function c1(w1,y1)local a2=w1.cursorY*w1.cols local x1,b2=w1.cursorX,w1.cols-1 if y1==1 then x1,b2=0,w1.cursorX elseif y1==2 then x1,b2=0,w1.cols-1 end for c2=x1,b2 do local z1=a2+c2+1 w1.grid[z1]=r(w1)j(w1,z1)end a(w1)end local function t1(w1,y1)for z1=1,#y1 do local x1=y1[z1]if x1==0 then w1.fg,w1.bg,w1.bold,w1.reverse=g,h,false,false elseif x1==1 then w1.bold=true elseif x1==7 then w1.reverse=true elseif x1==22 then w1.bold=false elseif x1==27 then w1.reverse=false elseif x1>=30 and x1<=37 then w1.fg=l[x1-29]elseif x1==39 then w1.fg=g elseif x1>=40 and x1<=47 then w1.bg=l[x1-39]elseif x1==49 then w1.bg=h elseif x1>=90 and x1<=97 then w1.fg=l[x1-81]elseif x1>=100 and x1<=107 then w1.bg=l[x1-91]end end end local function j1(w1)w1.fg,w1.bg,w1.bold,w1.reverse=g,h,false,false w1.cursorHidden=false w1.saved=nil m(w1)w1.cursorX,w1.cursorY=0,0 a(w1)b(w1)end local function d1(y1)local w1={}for x1 in(y1..";"):gmatch("([^;]*);")do w1[#w1+1]=tonumber(x1)or 0 end return w1 end local function i(w1)return(w1 and w1~=0)and w1 or 1 end local function i1(w1,x1,b2,z1,a2)if#a2>0 then return end local y1,c2=z1[1],z1[2]if x1=="m"then t1(w1,z1)elseif x1=="J"then y(w1,y1)elseif x1=="K"then c1(w1,y1)elseif x1=="H"or x1=="f"then e(w1,i(c2)-1,i(y1)-1)elseif x1=="A"then e(w1,w1.cursorX,w1.cursorY-i(y1))elseif x1=="B"then e(w1,w1.cursorX,w1.cursorY+i(y1))elseif x1=="C"then e(w1,w1.cursorX+i(y1),w1.cursorY)elseif x1=="D"then e(w1,w1.cursorX-i(y1),w1.cursorY)elseif x1=="E"then e(w1,0,w1.cursorY+i(y1))elseif x1=="F"then e(w1,0,w1.cursorY-i(y1))elseif x1=="G"then e(w1,i(y1)-1,w1.cursorY)elseif x1=="d"then e(w1,w1.cursorX,i(y1)-1)elseif x1=="s"then w(w1)elseif x1=="u"then q(w1)elseif b2=="?"and y1==25 then w1.cursorHidden=(x1=="l")a(w1)end end local function o1(w1,x1)local a2=w1.escState if a2==nil then if x1=="\27"then w1.escState,w1.escParams,w1.escInter="esc","",""else k(w1,x1)end return end local c2=string.byte(x1)if a2=="esc"then if x1=="["then w1.escState="csi"elseif x1=="]"then w1.escState="osc"elseif x1=="("or x1==")"or x1=="*"or x1=="+"then w1.escState="charset"elseif x1=="7"then w1.escState=nil;w(w1)elseif x1=="8"then w1.escState=nil;q(w1)elseif x1=="c"then w1.escState=nil;j1(w1)else w1.escState=nil end elseif a2=="charset"then w1.escState=nil elseif a2=="osc"then if x1=="\7"then w1.escState=nil elseif x1=="\27"then w1.escState="osc_esc"end elseif a2=="osc_esc"then w1.escState=nil elseif c2>=0x30 and c2<=0x3f then w1.escParams=w1.escParams..x1 elseif c2>=0x20 and c2<=0x2f then w1.escInter=w1.escInter..x1 elseif c2>=0x40 and c2<=0x7e then w1.escState=nil local b2,z1=w1.escParams,""local y1=b2:match("^([?<>=])")if y1 then z1=y1;b2=b2:sub(2)end i1(w1,x1,z1,d1(b2),w1.escInter)else w1.escState=nil end end local function n1(w1,x1)k(w1,x1)b(w1)end local function o(w1)if#w1.inputBuffer>0 then w1.inputBuffer=w1.inputBuffer:sub(1,-2)if w1.echo and w1.cursorX>0 then k(w1,"\b")k(w1," ")k(w1,"\b")b(w1)end end end local function s(w1)k(w1,"\n")b(w1)w1.lineQueue[#w1.lineQueue+1]=w1.inputBuffer w1.inputBuffer=""end local function h1(w1)w1.lineQueue[#w1.lineQueue+1]=w1.inputBuffer w1.inputBuffer=""end local function b1(w1,y1)for x1=1,#y1 do k(w1,y1:sub(x1,x1))end b(w1)end local function z(w1)w1.inputBuffer=""w1.eof=false if w1.reading then w1.intr=true end end local function a1(w1,x1)local y1=string.byte(x1 or"",1)if y1 and y1<0x20 and y1~=0x0A and y1~=0x0D and y1~=0x08 and y1~=0x09 then return end if x1=="\n"or x1=="\r"then s(w1)elseif x1=="\b"then o(w1)else w1.inputBuffer=w1.inputBuffer..x1 if w1.echo then n1(w1,x1)end end end local function e1(z1,x1,y1)if y1 then return end local w1=keys.getName(x1)if w1=="backspace"then o(z1)elseif w1=="enter"or w1=="return"or w1=="keypadenter"or w1=="keypad_enter"then s(z1)end end local n,x=false,false local f1={one=1,two=2,three=3,four=4,five=5,six=6,seven=7,eight=8,nine=9,zero=0}local function r1(w1)return w1=="leftCtrl"or w1=="rightCtrl"end local function u1(w1)return w1=="leftAlt"or w1=="rightAlt"end function f.routeKey(x1)local b2=x1[1]local a2=x1[2]local w1=keys.getName(a2)if not w1 then return end if r1(w1)then n=(b2=="key")return elseif u1(w1)then x=(b2=="key")return end if b2~="key"then return end if n and x then local c2=f1[w1]if c2 then local y1="tty"..tostring(c2-1)if c[y1]then f.setFocus(y1)end return end end if n and not x then if w1=="c"then if d and c[d]then f.ctrlC(c[d])end return elseif w1=="d"then if d and c[d]then f.ctrlD(c[d])end return elseif w1=="z"then if d and c[d]then f.ctrlZ(c[d])end return else return end end local z1=d and c[d]if z1 then e1(z1,a2,x1[3]or false)end end function f.feedInput(w1)local x1=d and c[d]if not x1 then return end local z1=w1[1]if z1=="char"then if n then return end a1(x1,tostring(w1[2]or""))elseif z1=="key"then e1(x1,w1[2],w1[3])elseif z1=="paste"then local y1=tostring(w1[2]or"")for a2=1,#y1 do a1(x1,y1:sub(a2,a2))end end end function f.raiseSignal(w1)if f.onSignal then f.onSignal(w1)end end function f.ctrlC(w1)if w1.echo then b1(w1,"^C\n")end z(w1)f.raiseSignal(l1.SIGINT)end function f.ctrlD(w1)if#w1.inputBuffer>0 then h1(w1)else w1.eof=true end end function f.ctrlZ(w1)if w1.echo then b1(w1,"^Z\n")end z(w1)f.raiseSignal(l1.SIGTSTP)end function f.setFocus(w1)if w1=="console"then d=nil for x1 in pairs(c)do if not d then d=x1 end end elseif c[w1]then d=w1 end return d end function f.getFocus()return d end local function v(w1,y1)local x1={isTTY=true,write=function(self,z1)if w1.closed then return nil,"device closed"end z1=tostring(z1 or"")for a2=1,#z1 do o1(w1,z1:sub(a2,a2))end b(w1)return#z1 end,writeLine=function(self,z1)if w1.closed then return nil,"device closed"end self:write((z1==nil or z1=="")and""or tostring(z1))self:write("\n")return(z1 and#z1 or 0)+1 end,clear=function(self,z1)if w1.closed then return nil,"device closed"end w1.bg=z1 or w1.bg m(w1)w1.cursorX,w1.cursorY=0,0 a(w1)b(w1)return true end,setCursor=function(self,z1,a2)if w1.closed then return nil,"device closed"end w1.cursorX=math.max(0,math.min(w1.cols-1,math.floor(z1 or 0)))w1.cursorY=math.max(0,math.min(w1.rows-1,math.floor(a2 or 0)))a(w1)b(w1)return true end,setTextColor=function(self,z1)w1.fg=z1;return true end,setBackgroundColor=function(self,z1)w1.bg=z1;return true end,setEcho=function(self,z1)w1.echo=(z1~=false);return true end,getCursor=function()return w1.cursorX,w1.cursorY end,getSize=function()return w1.cols,w1.rows end,getDeviceName=function()return w1.name end,flush=function()b(w1);return true end,close=function()return true end,}x1.readLine=function()if w1.closed then return nil,"device closed"end w1.reading=true while true do if f.readGuard and f.readGuard(w1.name)then os.pullEvent()elseif w1.eof then w1.eof=false w1.reading=false return nil elseif w1.intr then w1.intr=false w1.inputBuffer=""w1.reading=false return""elseif#w1.lineQueue>0 then local z1=table.remove(w1.lineQueue,1)w1.inputBuffer=""w1.reading=false return z1 else os.pullEvent()end end end x1.read=function()if w1.closed then return nil,"device closed"end return x1.readLine()end return x1 end function f.registerDevice(z1)local w1="tty"..t t=t+1 local x1=s1(z1)x1.name=w1 c[w1]=x1 if not d then d=w1 end local y1={writable=true,open=function(a2)return v(x1,a2)end,getCtx=function()return x1 end,}return w1,y1 end function f.get(w1)return c[w1]end function f.open(w1,y1)local x1=c[w1]if not x1 then return nil,"no such tty: "..tostring(w1)end return v(x1,y1)end function f.list()local w1={}for x1 in pairs(c)do w1[#w1+1]=x1 end table.sort(w1)return w1 end function f.resize(d2)local w1=c[d2]if not w1 then return end local b2=w1.dev local j2,h2=b2.getSize()local x1,y1 if b2.mode=="term"then x1=math.floor(j2)y1=math.floor(h2)else local f2=b2.cellW local e2=b2.cellH x1=math.floor(j2/f2)y1=math.floor(h2/e2)end local a2,c2=w1.cols,w1.rows local z1={}for k2=1,x1*y1 do z1[k2]={ch=" ",fg=g,bg=h}end for i2=0,math.min(y1,c2)-1 do for g2=0,math.min(x1,a2)-1 do z1[i2*x1+g2+1]=w1.grid[i2*a2+g2+1]end end w1.grid=z1 w1.cols,w1.rows=x1,y1 if w1.cursorX>=x1 then w1.cursorX=x1-1 end if w1.cursorY>=y1 then w1.cursorY=y1-1 end w1.dirty={}w1.dirtyList={}w1.cursorRenderedIdx=nil a(w1)for l2=1,x1*y1 do j(w1,l2)end b(w1)return true end function f.blinkTick()for x1,w1 in pairs(c)do if not w1.closed then w1.cursorOn=not w1.cursorOn a(w1)b(w1)end end end return f end __chunks["kernel.user"]=function()local _ENV=setmetatable({require=__require},{__index=_G})local a={}local c=require("kernel.modules")local function b(d)return(d:match("^%s*(.-)%s*$"))end function a.hash(d,f)local g=d..f local e=5381 for h=1,#g do e=((e*33)+g:byte(h))%0x100000000 end return string.format("%x",e)end function a.makeSalt(d)d=d or 8 local f="abcdefghijklmnopqrstuvwxyz0123456789"local e={}for h=1,d do local g=math.random(#f)e[h]=f:sub(g,g)end return table.concat(e)end function a.parse(k,m,o)local n={users={},groups={}}for f in(k or""):gmatch("[^\r\n]+")do f=b(f)if f~=""and f:sub(1,1)~="#"then local h,z,u,s,v,q,p=f:match("^([^:]+):([^:]*):([^:]+):([^:]+):([^:]*):([^:]*):([^:]*)$")if h then n.users[h]={name=h,uid=tonumber(u),gid=tonumber(s),home=q or"/home/"..h,shell=p}end end end for d in(m or""):gmatch("[^\r\n]+")do d=b(d)if d~=""and d:sub(1,1)~="#"then local j,r=d:match("^([^:]+):(.*)$")local w=j and n.users[j]if w then local l,x=r:match("^([^$]+)%$(%x+)$")if l then w.salt=l;w.hash=x end end end end for e in(o or""):gmatch("[^\r\n]+")do e=b(e)if e~=""and e:sub(1,1)~="#"then local g,y,t,i=e:match("^([^:]+):([^:]*):([^:]+):(.*)$")if g then n.groups[g]={name=g,gid=tonumber(t),members=b(i or"")}end end end return n end function a.verify(g,e,d)local f=g.users[e]if not f or not f.hash then return false end return a.hash(f.salt,d)==f.hash end function a.get(e,d)return e.users and e.users[d]end function a.byUid(e,d)for g,f in pairs(e.users)do if f.uid==d then return f end end return nil end function a.groupByName(e,d)return e.groups and e.groups[d]end function a.groupByGid(e,d)for g,f in pairs(e.groups or{})do if f.gid==d then return f end end return nil end function a.list(f)local d={}for e,g in pairs(f.users)do d[#d+1]=e..":"..g.uid end return d end function a.init(e)local function d(h)local f=e.open(h,"r")if not f then return""end local g=f.readAll();f.close()return g end return a.parse(d("/etc/passwd"),d("/etc/shadow"),d("/etc/group"))end function a.registerSyscalls(d)local e=c.syscalls()e["user.verify"]=function(f,g)return a.verify(d,f,g)end e["user.get"]=function(f)return a.get(d,f)end e["user.list"]=function()return a.list(d)end e["user.byUid"]=function(f)return a.byUid(d,f)end e["user.groupByName"]=function(f)return a.groupByName(d,f)end e["user.groupByGid"]=function(f)return a.groupByGid(d,f)end end return a end __chunks["kernel.version"]=function()local _ENV=setmetatable({require=__require},{__index=_G})return"0.0.2"end __chunks["kernel.vfs"]=function()local _ENV=setmetatable({require=__require},{__index=_G})local c={}local a={}local function b(f)if f==nil or f==""then return"/"end if f:sub(1,1)~="/"then f="/"..f end local g={}for h in f:gmatch("[^/]+")do if h==".."then if#g>0 then g[#g]=nil end elseif h~="."then g[#g+1]=h end end if#g==0 then return"/"end return"/"..table.concat(g,"/")end function c.mount(f,g,h)f=b(f)a[#a+1]={root=f,backend=g,meta=h}end function c.unmount(f)f=b(f)for g=#a,1,-1 do if a[g].root==f then table.remove(a,g)end end end local function e(f,g)if f=="/"then return true end return g==f or(g:sub(1,#f)==f and(g:sub(#f+1):sub(1,1)=="/"))end function c.list()local f={}for h,g in ipairs(a)do f[#f+1]={root=g.root,backend=g.backend,meta=g.meta}end return f end function c.resolve(g)g=b(g)local f=nil for j,i in ipairs(a)do if e(i.root,g)and(not f or#i.root>#f.root)then f=i end end if not f then return nil,nil,"path not under any mount: "..g end local h if f.root=="/"then h=g else if g==f.root then h=""else h=g:sub(#f.root+1)end end return f.backend,h,nil end local function d(g)local h={}local function f(i)return i==h end h.read=function(i,j)if f(i)then return g.read(j)end return g.read(i)end h.readAll=function()return g.readAll()end h.readLine=function(i,j)if f(i)then return g.readLine(j)end return g.readLine(i)end h.write=function(i,...)if f(i)then return g.write(...)end return g.write(i,...)end h.writeLine=function(i,...)if f(i)then return g.writeLine(...)end return g.writeLine(i,...)end h.seek=function(i,...)if f(i)then return g.seek(...)end return g.seek(i,...)end h.flush=function()return g.flush()end h.close=function()return g.close()end h.isReadOnly=function()return g.isReadOnly()end h.raw=g return h end function c.real(g)g=g or""if g~=""and g~="/"and g:sub(-1)=="/"then g=g:sub(1,-2)end local function f(h)if h==""then return g end if g==""then return h end return g..h end return{kind="real",toReal=f,list=function(h)return fs.list(f(h))end,exists=function(h)return fs.exists(f(h))end,isDir=function(h)return fs.isDir(f(h))end,isFile=function(h)return fs.exists(f(h))and not fs.isDir(f(h))end,attributes=function(h)return fs.attributes(f(h))end,getSize=function(h)return fs.getSize(f(h))end,getDrive=function(h)return fs.getDrive(f(h))end,getFreeSpace=function(h)return fs.getFreeSpace(f(h))end,getCapacity=function(h)return fs.getCapacity(f(h))end,makeDir=function(h)return fs.makeDir(f(h))end,move=function(h,i)return fs.move(f(h),f(i))end,copy=function(h,i)return fs.copy(f(h),f(i))end,delete=function(h)return fs.delete(f(h))end,isReadOnly=function(h)return fs.isReadOnly(f(h))end,open=function(j,h)local k,i=fs.open(f(j),h)if not k then return nil,i end return d(k)end,}end function c.virtual(f)f.kind="virtual"return f end return c end __chunks["kernel.vfs_api"]=function()local _ENV=setmetatable({require=__require},{__index=_G})local k=require("kernel.vfs")local c={}local d={}function c.registerDevice(m,l)d[m]=l end function c.unregisterDevice(l)d[l]=nil end local function g(l)return l and l:gsub("^/+","")or""end local h=k.virtual({list=function(m)local l={}for n in pairs(d)do l[#l+1]=n end table.sort(l)return l end,exists=function(l)l=g(l)if l==""then return true end return d[l]~=nil end,isDir=function(l)return g(l)==""end,attributes=function(l)if g(l)==""then return{size=0,isDir=true,isReadOnly=true,name="dev",created=0,modified=0}end if d[g(l)]then return{size=0,isDir=false,isReadOnly=true,name=g(l),created=0,modified=0}end return nil end,getSize=function(l)return 0 end,getDrive=function(l)return"vfs"end,getFreeSpace=function(l)return 0 end,getCapacity=function(l)return 0 end,isReadOnly=function(l)return true end,makeDir=function(l)error("read-only fs",2)end,move=function()error("read-only fs",2)end,copy=function()error("read-only fs",2)end,delete=function(l)error("read-only fs",2)end,open=function(n,m)local l=g(n)local o=d[l]if not o then return nil,"no such device: "..l end if not o.writable and m and m:find("w")then error("device is read-only: "..l,2)end if o.open then return o.open(m)end return nil,"device not openable: "..l end,})local b={}b.getName=fs.getName b.getDir=fs.getDir b.combine=fs.combine b.isDriveRoot=fs.isDriveRoot b.complete=fs.complete local function a(m)local l,o,n=k.resolve(m)if not l then error(tostring(n)or"bad path",2)end return l,o end function b.list(l)local m,n=a(l);return m.list(n)end function b.exists(l)local m,n=a(l);return m.exists(n)end function b.isDir(l)local m,n=a(l);return m.isDir(n)end function b.isReadOnly(l)local m,n=a(l);return m.isReadOnly(n)end function b.attributes(l)local m,n=a(l);return m.attributes(n)end function b.getSize(l)local m,n=a(l);return m.getSize(n)end function b.getDrive(l)local m,n=a(l);return m.getDrive(n)end function b.getFreeSpace(l)local m,n=a(l);return m.getFreeSpace(n)end function b.getCapacity(l)local m,n=a(l);return m.getCapacity(n)end function b.makeDir(l)local m,n=a(l);return m.makeDir(n)end function b.move(o,p)local l,m=a(o);local q,n=a(p);return l.move(m,n)end function b.copy(o,p)local l,m=a(o);local q,n=a(p);return l.copy(m,n)end function b.delete(l)local m,n=a(l);return m.delete(n)end function b.open(m,l)local n,o=a(m);return n.open(o,l)end function b.chmod(m,l)local n,o=a(m);if n.chmod then return n.chmod(o,l)end return nil,"chmod not supported"end function b.chown(l,n,m)local o,p=a(l);if o.chown then return o.chown(p,n,m)end return nil,"chown not supported"end function b.canExecute(l)local m,n=a(l);if m.canExecute then return m.canExecute(n)end return true end function b.isFile(l)local m,n=a(l)if m.isFile then return m.isFile(n)end return m.exists(n)and not m.isDir(n)end function b.find(n)local l={}local function m(s)local q,r=a(s)if q.exists(r)and q.isDir(r)then for u,t in ipairs(q.list(r))do local p=b.combine(s,t)m(p)end elseif q.exists(r)then l[#l+1]=s end end m(n)local o=0 return function()o=o+1;return l[o]end end local f=nil local e={}function e.open(m,l)return b.open(m,l or"r")end function e.type(l)if type(l)=="table"and getmetatable(l)and getmetatable(l).__ioType then return getmetatable(l).__ioType end if type(l)=="userdata"then return"file"end return nil end function e.close(l)if l and l.close then return l:close()end end function e.lines(l,...)if l then local m=b.open(l,"r")if not m then return function()return nil end end return m.lines and m.lines()or function()return m.readLine()end end return function()return nil end end local function j(l)return{open=e.open,type=e.type,close=e.close,lines=e.lines,write=function(...)local m={}for n=1,select("#",...)do m[n]=tostring(select(n,...))end if l.output then return l.output:write(table.concat(m))end return write(table.concat(m))end,read=function(...)if l.input then return l.input:read(...)end return read(...)end,flush=function()if l.output and l.output.flush then return l.output:flush()end end,stdout=function()return l.output end,stderr=function()return l.output end,stdin=function()return l.input end,}end function c.setStdio(m,l)f={input=m,output=l}end function c.getStdio()return f end function c.mountDev()k.mount("/dev",h,{device="devtmpfs",fstype="devtmpfs"})end local function i()return{read=function()return nil end,readLine=function()return nil end,write=function(m,l)return#tostring(l or"")end,flush=function()return true end,close=function()return true end,}end c.registerDevice("null",{writable=true,open=function()return i()end,})c.fs=b function c.devices()local l={}for m in pairs(d)do l[#l+1]=m end return l end function c.installForEnv(m)m.fs=b local l={input=nil,output=nil}m.__stdio=l m.io=j(l)end return c end __chunks["kernel.init_src"]=function()return[=[-- init bundle: 前 N-1 个为内部模块, 最后一个为顶层主程序
local __initMods, __initLoaded = {}, {}
local function __require(name)
    if __initLoaded[name] ~= nil then return __initLoaded[name] end
    local chunk = __initMods[name]
    if not chunk then error('init: module not found: ' .. tostring(name)) end
    local mod = chunk()
    __initLoaded[name] = mod
    return mod
end
__initMods["unit"] = function()
--[[ Delin init 单元文件解析 (systemd 风格子集)。
     单元文件是 INI 风格纯文本:
       [Unit]     Description= After= Before= Requires= Wants= Conflicts=
       [Service]  Type=simple|oneshot  ExecStart=  Restart=  RestartSec=
                  TimeoutStartSec=  TimeoutStopSec=  RemainAfterExit=
       [Timer]    OnBootSec=  OnActiveSec=  OnUnitActiveSec=  Unit=
       [Mount]    What=  Where=  Type=  Options=
       [Install]  WantedBy=
     值里可以出现多个空白分隔的单元名(After= a b); 同一个键可重复(等价于追加)。
     %i / %I 为模板实例名(getty@tty0.service 从 getty@.service 实例化)。
     本模块只做解析/字段归一化/模板替换, 不含任何运行状态。 ]]

local unit = {}

local KINDS = { service = true, target = true, timer = true, mount = true }

--- 单元名 -> 类型("service"|"target"|"timer"|"mount"), 非单元名返回 nil。
---@param name string
---@return string|nil
function unit.kind(name)
    local suffix = name:match("%.([%a]+)$")
    if suffix and KINDS[suffix] then return suffix end
    return nil
end

--- 解析单元文件文本。
---@param text string
---@param name string 单元名(用于错误消息)
---@param instance string|nil 模板实例名(%i/%I)
---@return table|nil rec, string|nil err
function unit.parse(text, name, instance)
    if instance then
        -- %% -> 哨兵, %i/%I -> 实例, 哨兵 -> %
        text = text:gsub("%%%%", "\1"):gsub("%%i", instance):gsub("%%I", instance):gsub("\1", "%%")
    end
    local rec = { name = name, sections = {} }
    local section = nil
    local lineno = 0
    for raw in (text .. "\n"):gmatch("([^\n]*)\n") do
        lineno = lineno + 1
        local line = raw:gsub("[;#].*$", ""):gsub("^%s+", ""):gsub("%s+$", "")
        if line ~= "" then
            local sec = line:match("^%[([^%]]+)%]$")
            if sec then
                section = sec
                rec.sections[section] = rec.sections[section] or {}
            elseif not section then
                return nil, string.format("%s:%d: key outside any section", name, lineno)
            else
                local k, v = line:match("^([%w_%-]+)%s*=%s*(.*)$")
                if not k then
                    return nil, string.format("%s:%d: not a Key=Value line: %s", name, lineno, line)
                end
                local secTab = rec.sections[section]
                secTab[k] = secTab[k] or {}
                secTab[k][#secTab[k] + 1] = v
            end
        end
    end
    return rec
end

--- 取某键的最后一个值(单值键)。
---@return string|nil
function unit.get(rec, section, key)
    local sec = rec.sections[section]
    local vals = sec and sec[key]
    return vals and vals[#vals] or nil
end

--- 取某键的全部值(空白分隔展开; 键可重复)。
---@return string[]
function unit.list(rec, section, key)
    local out = {}
    local sec = rec.sections[section]
    if sec and sec[key] then
        for _, v in ipairs(sec[key]) do
            for w in v:gmatch("%S+") do out[#out + 1] = w end
        end
    end
    return out
end

--- 取某键的原始字符串(保留空格, 如 ExecStart)。
function unit.raw(rec, section, key)
    return unit.get(rec, section, key)
end

--- 解析 systemd 风格时间: "10s" "5min" "1h" "2d" "500ms" 或纯数字(秒)。
---@param s string|nil
---@return number|nil seconds
function unit.time(s)
    if not s then return nil end
    s = s:gsub("%s+", "")
    local num, suffix = s:match("^([%d%.]+)(%a*)$")
    if not num then return nil end
    local n = tonumber(num)
    if not n then return nil end
    if suffix == "" or suffix == "s" or suffix == "sec" or suffix == "secs" or suffix == "second" or suffix == "seconds" then
        return n
    elseif suffix == "ms" or suffix == "msec" then
        return n / 1000
    elseif suffix == "min" or suffix == "mins" or suffix == "minute" or suffix == "minutes" then
        return n * 60
    elseif suffix == "h" or suffix == "hr" or suffix == "hour" or suffix == "hours" then
        return n * 3600
    elseif suffix == "d" or suffix == "day" or suffix == "days" then
        return n * 86400
    end
    return nil
end

--- 解析 ExecStart 风格命令行(systemd 子集: 空白分隔 + 单/双引号)。
---@param s string
---@return string[] argv  argv[1] 为程序路径
function unit.splitArgs(s)
    local out, i, n = {}, 1, #s
    while i <= n do
        local c = s:sub(i, i)
        if c:match("%s") then
            i = i + 1
        else
            local buf = {}
            while i <= n do
                c = s:sub(i, i)
                if c == '"' then
                    i = i + 1
                    local close = s:find('"', i, true)
                    if not close then break end
                    buf[#buf + 1] = s:sub(i, close - 1)
                    i = close + 1
                elseif c == "'" then
                    i = i + 1
                    local close = s:find("'", i, true)
                    if not close then break end
                    buf[#buf + 1] = s:sub(i, close - 1)
                    i = close + 1
                elseif c == "\\" and i < n then
                    buf[#buf + 1] = s:sub(i + 1, i + 1)
                    i = i + 2
                elseif c:match("%s") then
                    break
                else
                    buf[#buf + 1] = c
                    i = i + 1
                end
            end
            out[#out + 1] = table.concat(buf)
        end
    end
    return out
end

return unit

end
__initMods["service"] = function()
--[[ Delin init 服务引擎 (systemd 风格子集, 跑在 PID 1 的用户态里)。
     单元来源: /lib/systemd/system(厂商) 与 /etc/systemd/system(管理员, 同名覆盖),
     <target>.wants/ 与 <target>.requires/ 目录里的条目等价于在该 target 上加 Wants=/Requires=
     (Delin 的 CC 原生 fs 无符号链接, 故用同名空标记文件而非 systemd 的 symlink)。
     依赖: Requires(硬依赖, 失败则本单元不启动) / Wants(软依赖) / After/Before(仅排序) /
           Conflicts(启动前停掉冲突单元)。启动顺序 = 闭包 + 拓扑排序, 有环即 fail-fast。
     类型: service(Type=simple|oneshot, Restart=no|always|on-failure|on-abnormal, RestartSec=) /
           target / timer(OnBootSec= OnActiveSec= OnUnitActiveSec=) / mount(What= Where= Type=)。
     服务监督: init 注册 proc.onExit 钩子, 子进程退出时在此更新状态并按 Restart= 排定重启。
     本模块不做 I/O 阻塞, 唯一会让出的是等待 oneshot 启动完成(经 os.sleep, 由内核调度器驱动)。 ]]

local unitlib = __require("unit")

local svc = {}

svc.log = print          -- init 可换成带前缀的日志函数
svc.units = {}           -- name -> rec
svc.bootMs = 0           -- init 记录引导时刻(OnBootSec 基准)
local byPid = {}         -- pid -> rec(服务监督)

local UNIT_DIRS = { "/lib/systemd/system", "/etc/systemd/system" }
local STATE_DIR = "/etc/systemd/system" -- enable 标记写在这里(systemd 的 /etc 覆盖层)

local function log(...) svc.log(...) end

local function readFile(path)
    local f = fs.open(path, "r")
    if not f then return nil end
    local s = f.readAll()
    f.close()
    return s
end

--- 在单元目录里定位单元文件(支持 getty@tty0.service -> getty@.service 模板)。
---@param name string
---@return string|nil path, string|nil templatePath
local function findUnitFile(name)
    local kind = unitlib.kind(name)
    if not kind then return nil end
    local base, instance = name:match("^([^@]+)@(.+)%.[%a]+$")
    local template = base and (base .. "@." .. kind) or nil
    for i = #UNIT_DIRS, 1, -1 do -- 管理员目录优先(覆盖厂商)
        local dir = UNIT_DIRS[i]
        if fs.exists(dir .. "/" .. name) then return dir .. "/" .. name end
    end
    if template then
        for i = #UNIT_DIRS, 1, -1 do
            local dir = UNIT_DIRS[i]
            if fs.exists(dir .. "/" .. template) then return dir .. "/" .. template, instance end
        end
    end
end

--- 装载一个单元(按名字)。已在表中则直接返回。
---@param name string
---@return table|nil rec, string|nil err
function svc.get(name)
    local rec = svc.units[name]
    if rec then return rec end
    local path, instance = findUnitFile(name)
    if not path then return nil, name .. ": unit not found" end
    local text = readFile(path)
    if not text then return nil, path .. ": cannot read" end
    local parsed, err = unitlib.parse(text, name, instance)
    if not parsed then return nil, err end
    rec = svc.finalize(parsed, name, path)
    if not rec then return nil, name .. ": invalid unit" end
    svc.units[name] = rec
    return rec
end

--- 把解析结果归一化成运行时记录(校验 + 字段提取)。fail-fast: 非法值直接返回 nil+err。
---@param parsed table
---@param name string
---@param path string
---@return table|nil rec, string|nil err
function svc.finalize(parsed, name, path)
    local kind = unitlib.kind(name)
    if not kind then return nil, name .. ": unknown unit type" end
    local rec = {
        name = name, kind = kind, path = path, parsed = parsed,
        active = "inactive", sub = "dead",
        description = unitlib.get(parsed, "Unit", "Description") or name,
        requires = unitlib.list(parsed, "Unit", "Requires"),
        wants    = unitlib.list(parsed, "Unit", "Wants"),
        after    = unitlib.list(parsed, "Unit", "After"),
        before   = unitlib.list(parsed, "Unit", "Before"),
        conflicts= unitlib.list(parsed, "Unit", "Conflicts"),
        wantedBy = unitlib.list(parsed, "Install", "WantedBy"),
    }
    if kind == "service" then
        rec.type = (unitlib.get(parsed, "Service", "Type") or "simple"):lower()
        if rec.type ~= "simple" and rec.type ~= "oneshot" then
            return nil, name .. ": unsupported Type=" .. rec.type .. " (simple|oneshot)"
        end
        local exec = unitlib.raw(parsed, "Service", "ExecStart")
        if not exec or exec == "" then return nil, name .. ": missing ExecStart=" end
        local argv = unitlib.splitArgs(exec)
        rec.exec = argv[1]
        rec.execArgs = {}
        for i = 2, #argv do rec.execArgs[#rec.execArgs + 1] = argv[i] end
        rec.restart = (unitlib.get(parsed, "Service", "Restart") or "no"):lower()
        if not ({ no = true, always = true, ["on-failure"] = true, ["on-abnormal"] = true })[rec.restart] then
            return nil, name .. ": unsupported Restart=" .. rec.restart
        end
        rec.restartSec = unitlib.time(unitlib.get(parsed, "Service", "RestartSec")) or 1
        rec.timeoutStartSec = unitlib.time(unitlib.get(parsed, "Service", "TimeoutStartSec")) or 60
        rec.timeoutStopSec = unitlib.time(unitlib.get(parsed, "Service", "TimeoutStopSec")) or 10
        rec.remainAfterExit = (unitlib.get(parsed, "Service", "RemainAfterExit") or "no"):lower() == "yes"
        rec.startLimitBurst = tonumber(unitlib.get(parsed, "Service", "StartLimitBurst")) or 5
        rec.startLimitIntervalSec = unitlib.time(unitlib.get(parsed, "Service", "StartLimitIntervalSec")) or 10
    elseif kind == "timer" then
        local function sec(key)
            local v = unitlib.get(parsed, "Timer", key)
            if not v then return nil end
            local t = unitlib.time(v)
            if not t then error(name .. ": bad " .. key .. "=" .. v, 0) end
            return t
        end
        local ok, onBoot = pcall(sec, "OnBootSec")
        if not ok then return nil, onBoot end
        local ok2, onActive = pcall(sec, "OnActiveSec")
        if not ok2 then return nil, onActive end
        local ok3, onUnitActive = pcall(sec, "OnUnitActiveSec")
        if not ok3 then return nil, onUnitActive end
        rec.onBootSec, rec.onActiveSec, rec.onUnitActiveSec = onBoot, onActive, onUnitActive
        if unitlib.get(parsed, "Timer", "OnCalendar") then
            return nil, name .. ": OnCalendar= is not supported (use OnBootSec=/OnUnitActiveSec=)"
        end
        if not (onBoot or onActive or onUnitActive) then
            return nil, name .. ": timer needs OnBootSec=, OnActiveSec= or OnUnitActiveSec="
        end
        rec.unit = unitlib.get(parsed, "Timer", "Unit") or (name:gsub("%.timer$", ".service"))
    elseif kind == "mount" then
        rec.what = unitlib.get(parsed, "Mount", "What")
        rec.where = unitlib.get(parsed, "Mount", "Where")
        rec.fstype = unitlib.get(parsed, "Mount", "Type")
        rec.options = unitlib.get(parsed, "Mount", "Options")
        if not (rec.what and rec.where and rec.fstype) then
            return nil, name .. ": mount unit needs What=, Where= and Type="
        end
    end
    return rec
end

--- 扫描单元目录: 载入全部单元文件, 再把 <unit>.wants/.requires 标记目录折进依赖。
---@return integer count
function svc.loadAll()
    local keep = svc.units
    svc.units = {}
    local files = {}
    for _, dir in ipairs(UNIT_DIRS) do
        if fs.exists(dir) and fs.isDir(dir) then
            local names = fs.list(dir) or {}
            table.sort(names)
            for _, fn in ipairs(names) do
                if unitlib.kind(fn) and fs.exists(dir .. "/" .. fn) and not fs.isDir(dir .. "/" .. fn) then
                    files[fn] = dir .. "/" .. fn -- 后扫到的目录(/etc)覆盖厂商
                end
            end
        end
    end
    local n = 0
    for name, path in pairs(files) do
        local text = readFile(path)
        if not text then
            log("[init] " .. path .. ": cannot read")
        else
            local parsed, err = unitlib.parse(text, name)
            if not parsed then
                log("[init] " .. tostring(err))
            else
                local rec = svc.finalize(parsed, name, path)
                if not rec then
                    log("[init] " .. name .. ": invalid unit")
                else
                    svc.units[name] = rec
                    n = n + 1
                end
            end
        end
    end
    -- <unit>.wants / <unit>.requires 目录
    for _, dir in ipairs(UNIT_DIRS) do
        if fs.exists(dir) and fs.isDir(dir) then
            for _, sub in ipairs(fs.list(dir) or {}) do
                local owner, depKind = sub:match("^(.+%.[%a]+)%.wants$"), "wants"
                if not owner then owner, depKind = sub:match("^(.+%.[%a]+)%.requires$"), "requires" end
                if owner and unitlib.kind(owner) then
                    local rec = svc.units[owner]
                    if not rec then
                        rec = { name = owner, kind = unitlib.kind(owner), path = "(implicit)", parsed = { name = owner, sections = {} },
                                active = "inactive", sub = "dead", description = owner,
                                requires = {}, wants = {}, after = {}, before = {}, conflicts = {}, wantedBy = {} }
                        svc.units[owner] = rec
                    end
                    local full = dir .. "/" .. sub
                    if fs.isDir(full) then
                        for _, dep in ipairs(fs.list(full) or {}) do
                            if unitlib.kind(dep) then
                                local list = (depKind == "wants") and rec.wants or rec.requires
                                local dup = false
                                for _, x in ipairs(list) do if x == dep then dup = true; break end end
                                if not dup then list[#list + 1] = dep end
                            end
                        end
                    end
                end
            end
        end
    end
    -- 重载时保留仍在运行的服务的状态
    for name, old in pairs(keep) do
        local rec = svc.units[name]
        if rec and old.pid and old.active ~= "inactive" then
            rec.active, rec.sub, rec.pid, rec.startMs = old.active, old.sub, old.pid, old.startMs
            byPid[old.pid] = rec
        end
    end
    return n
end

--- 把新单元注入内存(init 生成的 fstab mount 单元 / getty 实例)。
---@param rec table
function svc.add(rec)
    svc.units[rec.name] = rec
end

--- 给某单元追加 Wants/Requires 依赖(不存在则创建隐式 target 记录)。
function svc.addDep(owner, dep, hard)
    local rec = svc.units[owner]
    if not rec then
        rec = { name = owner, kind = unitlib.kind(owner), path = "(implicit)", parsed = { name = owner, sections = {} },
                active = "inactive", sub = "dead", description = owner,
                requires = {}, wants = {}, after = {}, before = {}, conflicts = {}, wantedBy = {} }
        svc.units[owner] = rec
    end
    local list = hard and rec.requires or rec.wants
    for _, x in ipairs(list) do if x == dep then return end end
    list[#list + 1] = dep
end

--- 计算启动顺序: 从 root 出发收集 Requires/Wants 闭包, 按 After/Before 拓扑排序。
---@param root string
---@return string[]|nil order, string|nil err
function svc.startOrder(root)
    local closure, stack = {}, { { name = root, hard = true } }
    while #stack > 0 do
        local item = table.remove(stack)
        local n = item.name
        if not closure[n] then
            local rec, err = svc.get(n)
            if not rec then
                if item.hard then return nil, err end
                log("[init] " .. n .. ": " .. tostring(err) .. " (soft dependency, skipped)")
            else
                closure[n] = rec
                for _, d in ipairs(rec.requires) do stack[#stack + 1] = { name = d, hard = true } end
                for _, d in ipairs(rec.wants) do stack[#stack + 1] = { name = d, hard = false } end
            end
        end
    end
    local indeg, adj = {}, {}
    for n in pairs(closure) do indeg[n] = 0; adj[n] = {} end
    local function edge(a, b)
        if a ~= b and closure[a] and closure[b] then
            for _, x in ipairs(adj[a]) do if x == b then return end end
            adj[a][#adj[a] + 1] = b
            indeg[b] = indeg[b] + 1
        end
    end
    for n, rec in pairs(closure) do
        for _, a in ipairs(rec.after) do edge(a, n) end
        for _, b in ipairs(rec.before) do edge(n, b) end
        -- systemd.target(5): target 的 Requires=/Wants= 自动补 After= ——
        -- target 只有在它拉起的单元都启动后才算 active。
        if rec.kind == "target" then
            for _, d in ipairs(rec.requires) do edge(d, n) end
            for _, d in ipairs(rec.wants) do edge(d, n) end
        end
    end
    local order, ready = {}, {}
    for n, d in pairs(indeg) do if d == 0 then ready[#ready + 1] = n end end
    table.sort(ready)
    local total = 0
    for _ in pairs(closure) do total = total + 1 end
    while #ready > 0 do
        local n = table.remove(ready, 1)
        order[#order + 1] = n
        for _, m in ipairs(adj[n]) do
            indeg[m] = indeg[m] - 1
            if indeg[m] == 0 then ready[#ready + 1] = m; table.sort(ready) end
        end
    end
    if #order < total then
        local cyc = {}
        for n, d in pairs(indeg) do if d > 0 then cyc[#cyc + 1] = n end end
        table.sort(cyc)
        return nil, "ordering cycle among: " .. table.concat(cyc, " ")
    end
    return order
end

local function markFailed(rec, why)
    rec.active, rec.sub = "failed", "failed"
    rec.failReason = why
    log("[init] " .. rec.name .. ": FAILED: " .. tostring(why))
end

--- 记录一次启动尝试; 超过 StartLimitBurst/StartLimitIntervalSec 则拒绝重启
--- (systemd 的 start limit: 防止配置错误的服务无限重启刷屏)。
---@return boolean allowed
local function noteStart(rec)
    local now = os.epoch("utc")
    rec.startTimes = rec.startTimes or {}
    local window = (rec.startLimitIntervalSec or 10) * 1000
    local keep = {}
    for _, t in ipairs(rec.startTimes) do
        if now - t < window then keep[#keep + 1] = t end
    end
    keep[#keep + 1] = now
    rec.startTimes = keep
    return #keep <= (rec.startLimitBurst or 5)
end

local function scheduleRestart(rec)
    if not noteStart(rec) then
        markFailed(rec, "start request repeated too quickly (StartLimitBurst=" .. rec.startLimitBurst .. ")")
        return
    end
    rec.restartAt = os.epoch("utc") + math.floor(rec.restartSec * 1000)
    rec.active, rec.sub = "activating", "auto-restart"
end

--- 启动单个单元(不做依赖检查, 由 svc.start 保证顺序)。
---@return boolean|nil ok, string|nil err
local function startOne(rec)
    if rec.kind == "target" then
        rec.active, rec.sub = "active", "active"
        return true
    elseif rec.kind == "timer" then
        rec.active, rec.sub = "active", "waiting"
        local now = os.epoch("utc")
        rec.next = rec.onBootSec and (svc.bootMs + rec.onBootSec * 1000) or (now + rec.onActiveSec * 1000)
        return true
    elseif rec.kind == "mount" then
        for _, m in ipairs(syscalls["fs.mounts"]()) do
            if m.root == rec.where then
                rec.active, rec.sub = "active", "mounted"
                log("[init] " .. rec.name .. ": " .. rec.where .. " already mounted, skipping")
                return true
            end
        end
        if not fs.exists(rec.where) then fs.makeDir(rec.where) end
        local ok, info = syscalls["fs.mount"](rec.what, rec.where, rec.fstype)
        if not ok then return nil, rec.what .. " -> " .. rec.where .. ": " .. tostring(info) end
        rec.active, rec.sub = "active", "mounted"
        rec.mounted = info
        return true
    elseif rec.kind == "service" then
        -- ppid=1: 服务挂在 init 名下(与 systemd 一致), 而不是发起 systemctl 的进程。
        local pid, err = syscalls["proc.spawnFile"](rec.exec, rec.execArgs, { cwd = "/", ppid = 1 })
        if not pid then return nil, rec.exec .. ": " .. tostring(err) end
        rec.pid = pid
        rec.exitCode, rec.termSig = nil, nil
        rec.startMs = os.epoch("utc")
        byPid[pid] = rec
        if rec.type == "oneshot" then
            rec.active, rec.sub = "activating", "start"
        else
            rec.active, rec.sub = "active", "running"
        end
        return true
    end
    return nil, rec.name .. ": unsupported unit kind"
end

--- 等待一个 oneshot 完成启动(或失败)。
--- 等待期间照常驱动引擎(延迟重启/timer/超时), 否则 init 会卡在一个慢 oneshot 上,
--- 让 timer 与重启排期停摆。
local function waitUnit(rec)
    local deadline = os.epoch("utc") + rec.timeoutStartSec * 1000
    while rec.active == "activating" do
        if os.epoch("utc") > deadline then
            markFailed(rec, "start timeout")
            if rec.pid then syscalls["signal.kill"](rec.pid, 9) end
            return
        end
        svc.tick()
        os.sleep(0.05)
    end
end

--- 启动一个单元(含其 Requires/Wants 闭包), 按依赖拓扑序执行。
---@param name string
---@return boolean|nil ok, string|nil err
function svc.start(name)
    local order, err = svc.startOrder(name)
    if not order then return nil, err end
    -- 显式 start 的根单元允许重试(等价 systemd 的 systemctl start 重试 failed 单元);
    -- 依赖链上已经 failed 的单元不再重试, 否则"坏配置"会被静默修好。
    local rootRec = svc.units[name]
    if rootRec and rootRec.active == "failed" then
        rootRec.active, rootRec.sub, rootRec.failReason = "inactive", "dead", nil
    end
    local failed = {}
    for _, n in ipairs(order) do
        local rec = svc.units[n]
        if rec.active == "failed" then
            failed[n] = true
        elseif rec.active ~= "active" and rec.active ~= "activating" then
            -- 硬依赖必须已 active
            local bad
            for _, d in ipairs(rec.requires) do
                local dr = svc.units[d]
                if not dr or dr.active ~= "active" then bad = d; break end
            end
            if bad then
                failed[n] = true
                markFailed(rec, "dependency failed: " .. bad)
            else
                -- Conflicts=: 启动前停掉冲突单元
                for _, c in ipairs(rec.conflicts) do
                    local cr = svc.units[c]
                    if cr and cr.active ~= "inactive" then svc.stop(c) end
                end
                local ok, e = startOne(rec)
                if not ok then failed[n] = true; markFailed(rec, e) end
            end
        end
        if rec.kind == "service" and rec.type == "oneshot" and rec.active == "activating" then
            waitUnit(rec)
        end
    end
    if failed[name] or svc.units[name].active == "failed" then
        return nil, svc.units[name].name .. ": " .. tostring(svc.units[name].failReason or "failed")
    end
    return true
end

--- 停止一个单元(服务发 SIGTERM, 超时 SIGKILL; mount 卸载)。
---@return boolean|nil ok, string|nil err
function svc.stop(name)
    local rec, err = svc.get(name)
    if not rec then return nil, err end
    if rec.kind == "mount" then
        local ok, uerr = syscalls["fs.umount"](rec.where)
        if not ok then return nil, uerr end
        rec.active, rec.sub = "inactive", "dead"
        return true
    end
    if rec.kind ~= "service" then
        rec.active, rec.sub = "inactive", "dead"
        return true
    end
    if rec.pid then
        rec.stopping = true
        rec.active, rec.sub = "deactivating", "stop"
        rec.stopMs = os.epoch("utc")
        local ok, kerr = syscalls["signal.kill"](rec.pid, 15)
        if not ok then return nil, kerr end
    else
        rec.active, rec.sub = "inactive", "dead"
    end
    return true
end

--- 重启一个单元: 若正在运行则停掉并在退出后重新启动(退出钩子里排定)。
---@return boolean|nil ok, string|nil err
function svc.restart(name)
    local rec, err = svc.get(name)
    if not rec then return nil, err end
    if rec.active == "active" or rec.active == "activating" or rec.active == "deactivating" then
        rec.restartPending = true
        return svc.stop(name)
    end
    return svc.start(name)
end

--- 子进程退出钩子(init 注册到内核 proc.onExit)。不得让出。
---@param pid integer
---@param status string "dead"|"error"
---@param code integer|nil
---@param termSig integer|nil
function svc.onProcessExit(pid, status, code, termSig)
    local rec = byPid[pid]
    if not rec then return end
    byPid[pid] = nil
    rec.pid = nil
    rec.exitCode, rec.termSig = code, termSig

    if rec.stopping or rec.active == "deactivating" then
        rec.stopping = nil
        rec.active, rec.sub = "inactive", "dead"
        if rec.restartPending then
            rec.restartPending = nil
            log("[init] " .. rec.name .. ": restarted")
            scheduleRestart(rec)
        end
        return
    end

    local okExit = (code == 0) and not termSig
    if rec.type == "oneshot" then
        if okExit then
            if rec.remainAfterExit then rec.active, rec.sub = "active", "exited"
            else rec.active, rec.sub = "inactive", "dead" end
        else
            markFailed(rec, "exit code " .. tostring(code) .. (termSig and (" signal " .. termSig) or ""))
        end
    elseif okExit then
        rec.active, rec.sub = "inactive", "dead"
    else
        markFailed(rec, "exit code " .. tostring(code) .. (termSig and (" signal " .. termSig) or ""))
    end

    local should
    if rec.restart == "always" then should = true
    elseif rec.restart == "on-failure" then should = not okExit
    elseif rec.restart == "on-abnormal" then should = termSig ~= nil end
    if should then
        log("[init] " .. rec.name .. ": exited, restarting in " .. rec.restartSec .. "s")
        scheduleRestart(rec)
    end
end

--- 周期驱动: 延迟重启 / timer 到期 / oneshot 与 stop 超时。init 主循环每 100ms 调用。
function svc.tick()
    local now = os.epoch("utc")
    for _, rec in pairs(svc.units) do
        if rec.restartAt and now >= rec.restartAt then
            rec.restartAt = nil
            local ok, err = startOne(rec)
            if not ok then markFailed(rec, err) end
        end
        if rec.kind == "timer" and rec.active == "active" and not rec.firing
            and rec.next and now >= rec.next then
            -- 先把下一次到期时间排好, 再启动 Unit=: svc.start 可能驱动 tick(等待 oneshot),
            -- 若此时 next 仍到期会重复触发同一个 timer(曾导致无限递归)。
            rec.firing = true
            rec.sub = "running"
            if rec.onUnitActiveSec then rec.next = now + rec.onUnitActiveSec * 1000
            else rec.next = nil end
            log("[timer] " .. rec.name .. " -> " .. rec.unit)
            local ok, err = svc.start(rec.unit)
            if not ok then log("[timer] " .. rec.name .. ": " .. tostring(err)) end
            rec.firing = nil
            if rec.onUnitActiveSec then
                rec.sub = "waiting"
            else
                rec.active, rec.sub = "inactive", "elapsed"
            end
        end
        if rec.active == "activating" and rec.startMs and rec.timeoutStartSec
            and now - rec.startMs > rec.timeoutStartSec * 1000 and not rec.restartAt then
            log("[init] " .. rec.name .. ": start timeout, killing pid " .. tostring(rec.pid))
            if rec.pid then syscalls["signal.kill"](rec.pid, 9) end
        end
        if rec.active == "deactivating" and rec.stopMs and now - rec.stopMs > rec.timeoutStopSec * 1000 then
            log("[init] " .. rec.name .. ": stop timeout, SIGKILL pid " .. tostring(rec.pid))
            if rec.pid then syscalls["signal.kill"](rec.pid, 9) end
            rec.stopMs = nil
        end
    end
end

--- 单元状态快照(供 systemctl)。
function svc.snapshot(name)
    local rec = svc.get(name)
    if not rec then return nil end
    return {
        name = rec.name, kind = rec.kind, description = rec.description,
        active = rec.active, sub = rec.sub, pid = rec.pid, path = rec.path,
        exec = rec.exec, exitCode = rec.exitCode, termSig = rec.termSig,
        failReason = rec.failReason, enabled = svc.isEnabled(rec.name),
        next = rec.next, unit = rec.unit, startMs = rec.startMs,
        where = rec.where, what = rec.what, wantedBy = rec.wantedBy,
    }
end

--- 列出全部已装载单元(按名字排序)。
function svc.list()
    local out = {}
    for name in pairs(svc.units) do out[#out + 1] = name end
    table.sort(out)
    local res = {}
    for _, n in ipairs(out) do res[#res + 1] = svc.snapshot(n) end
    return res
end

--- enable 标记路径(systemd 的 <target>.wants/<unit> 空标记文件)。
local function markerPath(unitName, targetName)
    return STATE_DIR .. "/" .. targetName .. ".wants/" .. unitName
end

--- 单元是否 enabled([Install] WantedBy= 目标下存在标记)。
---@param name string
---@return boolean
function svc.isEnabled(name)
    local rec = svc.units[name] or select(1, svc.get(name))
    if not rec then return false end
    for _, target in ipairs(rec.wantedBy) do
        for _, dir in ipairs(UNIT_DIRS) do
            if fs.exists(dir .. "/" .. target .. ".wants/" .. name) then return true end
        end
    end
    return false
end

--- 启用单元(按 [Install] WantedBy= 写标记文件)。
---@return boolean|nil ok, string|nil err
function svc.enable(name)
    local rec, err = svc.get(name)
    if not rec then return nil, err end
    if #rec.wantedBy == 0 then return nil, name .. ": no [Install] WantedBy= (nothing to enable)" end
    for _, target in ipairs(rec.wantedBy) do
        local dir = STATE_DIR .. "/" .. target .. ".wants"
        if not fs.exists(dir) then fs.makeDir(dir) end
        local f = fs.open(markerPath(name, target), "w")
        if not f then return nil, "cannot create " .. markerPath(name, target) end
        f.close()
        svc.addDep(target, name, false)
        log("[init] enabled " .. name .. " -> " .. target)
    end
    return true
end

--- 禁用单元(删除标记文件)。
---@return boolean|nil ok, string|nil err
function svc.disable(name)
    local rec, err = svc.get(name)
    if not rec then return nil, err end
    if #rec.wantedBy == 0 then return nil, name .. ": no [Install] WantedBy= (nothing to disable)" end
    for _, target in ipairs(rec.wantedBy) do
        local p = markerPath(name, target)
        if fs.exists(p) then fs.delete(p) end
        log("[init] disabled " .. name)
    end
    return true
end

return svc

end
--[[ Delin PID 1 (init) —— 用户态服务管理器 (systemd 风格子集)。
     运行在隔离进程环境中(pid/ppid/spawn/print/fs/syscalls 由内核注入, 其余原始 API 直用)。

     启动序列:
       1. 建立 /run、/var/log(真实目录, 非 tmpfs —— Delin 无 tmpfs)
       2. 安装信号处理(SIGTERM/SIGINT/SIGQUIT -> 关机, SIGHUP -> 重载单元)
       3. 装载单元(/lib/systemd/system + /etc/systemd/system, .wants/.requires 标记目录)
       4. 由 /etc/fstab 生成 <mountpoint>.mount 单元并挂到 local-fs.target
       5. 为每个 /dev/ttyN 实例化 getty@ttyN.service 并挂到 getty.target
       6. 注册 init.* 控制 syscall(systemctl 的私有控制通道; Delin 无 Unix socket/D-Bus)
       7. 启动 default.target; 失败或缺失则进入 rescue(每个 tty 起 login)
       8. 主循环: 驱动服务引擎(timer/延迟重启/超时)直到收到关机请求

     不做任何自检 —— 测试代码见 scripts/ 与宿主测试台 tools/harness.lua。 ]]

local unitlib = __require("unit")
local svc     = __require("service")

local bootMs = os.epoch("utc")
svc.bootMs = bootMs
svc.log = function(...) print(...) end

local shutdownRequested = false
local reloadRequested = false

local function log(msg) print("[init] " .. tostring(msg)) end

-- ---------------------------------------------------------------
-- 信号: PID 1 不接受 ^C/^Z 之类的交互信号影响; 收到关机信号则走正常停机
-- ---------------------------------------------------------------
syscalls["signal.install"](15, function() shutdownRequested = true end) -- SIGTERM
syscalls["signal.install"](2,  function() shutdownRequested = true end) -- SIGINT
syscalls["signal.install"](3,  function() shutdownRequested = true end) -- SIGQUIT
syscalls["signal.install"](1,  function() reloadRequested = true end)   -- SIGHUP: daemon-reload
syscalls["signal.install"](20, function() end)                          -- SIGTSTP: 忽略
syscalls["signal.install"](21, function() end)                          -- SIGTTIN: 忽略
syscalls["signal.install"](22, function() end)                          -- SIGTTOU: 忽略

-- ---------------------------------------------------------------
-- 目录: /run(pid 文件)、/var/log(日志)。缺失即建, 建不了则 fail-fast 报错。
-- ---------------------------------------------------------------
for _, dir in ipairs({ "/run", "/var/log" }) do
    if not fs.exists(dir) then
        fs.makeDir(dir)
        if not fs.exists(dir) then error("init: cannot create " .. dir, 0) end
        log("created " .. dir)
    end
end

-- ---------------------------------------------------------------
-- 单元生成: /etc/fstab -> mount 单元
-- ---------------------------------------------------------------
local function generateFstabUnits()
    local entries, err = syscalls["fstab.entries"]()
    if not entries then
        -- 坏 fstab 一律 fail-fast: local-fs.target 失败 -> multi-user.target 失败 -> rescue
        log("FATAL: /etc/fstab: " .. tostring(err))
        local rec = svc.units["local-fs.target"]
        if rec then rec.active, rec.sub, rec.failReason = "failed", "failed", tostring(err) end
        return
    end
    for _, e in ipairs(entries) do
        if e.opts.noauto then
            log("fstab: " .. e.mountpoint .. " (noauto, skipped)")
        else
            local rec = {
                name = e.unit, kind = "mount", path = "/etc/fstab:" .. e.line,
                active = "inactive", sub = "dead",
                description = e.device .. " on " .. e.mountpoint,
                requires = {}, wants = {}, before = { "local-fs.target" },
                after = { "local-fs-pre.target" }, conflicts = {}, wantedBy = {},
                what = e.device, where = e.mountpoint, fstype = e.fstype, options = e.options,
            }
            svc.add(rec)
            svc.addDep("local-fs.target", rec.name, not e.opts.nofail)
            log("fstab: " .. e.unit .. " <- " .. e.device .. " " .. e.mountpoint
                .. " " .. e.fstype .. (e.opts.nofail and " (nofail)" or ""))
        end
    end
end

-- ---------------------------------------------------------------
-- 单元生成: 每个 /dev/ttyN 一个 getty@ttyN.service
-- ---------------------------------------------------------------
local function generateGettys()
    local ttys = syscalls["tty.list"]()
    local missing = false
    for _, tn in ipairs(ttys) do
        local name = "getty@" .. tn .. ".service"
        local rec, err = svc.get(name)
        if not rec then
            if not missing then
                log("getty@.service not available: " .. tostring(err))
                missing = true
            end
        else
            svc.add(rec)
            svc.addDep("getty.target", name, false)
        end
    end
    return #ttys
end

-- ---------------------------------------------------------------
-- rescue: 无可用 default.target(未部署单元 / 依赖启动失败)时, 每个 tty 起一个 login。
-- 等价 systemd 的 emergency/rescue 模式: 给管理员一个能修配置的 shell。
-- ---------------------------------------------------------------
local function rescue(reason)
    log("rescue mode: " .. reason)
    for _, rec in ipairs(svc.list()) do
        if rec.active ~= "inactive" then pcall(svc.stop, rec.name) end
    end
    local f = fs.open("/bin/login", "r")
    if not f then
        log("FATAL: /bin/login not found, no rescue shell")
        return
    end
    local src = f.readAll()
    f.close()
    for _, tn in ipairs(syscalls["tty.list"]()) do
        local lpid = spawn(src, "login", 0, 0, { [0] = "/bin/login", tn })
        log("rescue: login on " .. tn .. " pid=" .. tostring(lpid))
    end
end

-- ---------------------------------------------------------------
-- 控制接口: systemctl 经共享 syscall 表调用(等价的 private socket)。
-- 这些函数在调用者(systemctl)的进程上下文里执行; 需要等待时由调用者协程让出。
-- ---------------------------------------------------------------
local function registerControl()
    syscalls["init.start"]     = function(name) return svc.start(name) end
    syscalls["init.stop"]      = function(name) return svc.stop(name) end
    syscalls["init.restart"]   = function(name) return svc.restart(name) end
    syscalls["init.status"]    = function(name) return svc.snapshot(name) end
    syscalls["init.list"]      = function() return svc.list() end
    syscalls["init.enable"]    = function(name) return svc.enable(name) end
    syscalls["init.disable"]   = function(name) return svc.disable(name) end
    syscalls["init.isEnabled"] = function(name) return svc.isEnabled(name) end
    syscalls["init.reload"]    = function() reloadRequested = true; return true end
    syscalls["init.shutdown"]  = function() shutdownRequested = true; return true end
    syscalls["init.bootTime"]  = function() return bootMs end
end

-- ---------------------------------------------------------------
-- 装载 + 启动
-- ---------------------------------------------------------------
local function loadUnits()
    local n = svc.loadAll()
    log("loaded " .. n .. " unit(s) from /lib/systemd/system + /etc/systemd/system")
    generateFstabUnits()
    local nTty = generateGettys()
    log("generated getty on " .. nTty .. " tty(s)")
end

syscalls["proc.onExit"](svc.onProcessExit) -- 服务监督: 子进程退出回调
registerControl()
loadUnits()

local ok, err = svc.start("default.target")
if not ok then
    rescue(tostring(err))
end

-- ---------------------------------------------------------------
-- 主循环: 驱动服务引擎; init 永不退出(除非收到关机请求)
-- ---------------------------------------------------------------
log("init up (pid " .. pid .. "), default.target " .. (ok and "active" or "FAILED"))
while not shutdownRequested do
    if reloadRequested then
        reloadRequested = false
        log("reloading units (daemon-reload)")
        loadUnits()
    end
    svc.tick()
    os.sleep(0.1)
end

log("shutting down: stopping all units")
for _, rec in ipairs(svc.list()) do
    if rec.active ~= "inactive" then pcall(svc.stop, rec.name) end
end
os.sleep(1)
log("init: bye")
]=]end __require('kernel.boot').boot()
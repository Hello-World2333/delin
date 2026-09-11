local __chunks={}local __loaded={}local function __require(a)if __loaded[a]then return __loaded[a]end local b=assert(__chunks[a],'module not found: '..a)local c=b()__loaded[a]=c return c end __chunks["kernel.blockdev"]=function()local _ENV=setmetatable({require=__require},{__index=_G})local a={}local b={}function a.register(c,d)b[c]=d end function a.get(c)return b[c]end function a.names()local c={}for d in pairs(b)do c[#c+1]=d end return c end function a.file(e)local c,f=fs.open(e,"r+")if not c then return nil,f or("cannot open "..e)end local d=0 local g={kind="file",path=e,handle=c,blockSize=512,read=function(h,j)if h~=d then local k,l=c.seek("set",h)if not k then return nil,tostring(l)end d=h end local i=c.read(j)d=d+#(i or"")return i end,write=function(h,i)if h~=d then local k,m=c.seek("set",h)if not k then return nil,tostring(m)end d=h end local l,j=c.write(i)d=h+#i if l==nil and j~=nil then return nil,j end return true end,getSize=function()return fs.getSize(e)end,close=function()c.close()end,}return g end return a end __chunks["kernel.boot"]=function()local _ENV=setmetatable({require=__require},{__index=_G})local p=require("kernel.scheduler")local d=require("kernel.process")local w=require("kernel.vfs")local c=require("kernel.vfs_api")local h=require("kernel.devdisk")local b=require("kernel.modules")local e1=require("kernel.ext2")local s=require("kernel.tty")local h1=require("kernel.fb")local b1=require("kernel.display")local a1=require("kernel.sysfs")local u=require("kernel.procfs")local g1=require("kernel.pipe")local j=require("kernel.klog")local f1=require("kernel.fstab")local n=require("kernel.init_src")local g=nil local k=nil local x=j.makePri(j.FACILITIES.kern,j.SEVERITIES.info)local y=j.makePri(j.FACILITIES.user,j.SEVERITIES.info)local function d1(l1,...)local j1={}for n1=1,select("#",...)do j1[n1]=tostring(select(n1,...))end local k1=os.epoch("utc")local m1=(k and(k1-k))or 0 local i1=string.format("[%8.3f] %s",m1/1000,table.concat(j1,"\t"))j.write(l1,i1)if g then g.writeLine(i1);g.flush()end write(i1.."\n")end local function a(...)return d1(x,...)end local function v(...)return d1(y,...)end local function z()w.mount("/",w.real(""),{device="rootfs",fstype="ccdisk"})c.mountDev()j.register()u.mount(k,b.version)c.setStdio({read=function(self,...)return read(...)end},{write=function(self,i1)return write(i1)end,writeLine=function(self,i1)return write(i1.."\n")end,flush=function(self)return true end})end local function l()local j1=h.refresh()local i1={}for l1,k1 in ipairs(j1)do i1[#i1+1]=k1.name.."("..k1.fstype..(k1.uuid and(",uuid="..k1.uuid)or"")..")"end a("block devices: "..(#i1>0 and table.concat(i1," ")or"(none)"))p.setDiskHook(function()h.refresh()end)end local function q()local i1="/lib/modules/"..b.version if fs.exists(i1.."/manifest")then return i1 end return nil end local function o()if not c.fs.exists("/etc/passwd")then a("FATAL: /etc/passwd not found on root (no user can log in)")return nil end local j1=require("kernel.user")local k1=j1.init(c.fs)j1.registerSyscalls(k1,c.fs)local i1={}for m1,l1 in ipairs(j1.list(k1))do i1[#i1+1]=l1.name end a("users loaded: "..table.concat(i1,","))return k1 end local function t(i1,j1)if type(i1)~="string"then a("FATAL: "..j1.." init source missing");return end local k1,m1,l1=d.spawn(i1,"init",0)if not k1 then a("FATAL: spawn "..j1.." init failed: "..tostring(l1));return end a("spawned "..j1.." init as pid #"..k1)a("running scheduler (all processes concurrently) ...")p.run()a("kernel: all processes exited, shutting down")if g then g.close();g=nil end end local function e()local i1=b.syscalls()i1["tty.list"]=function()return s.list()end i1["fb.list"]=function()return h1.list()end end local function f()local i1=b.syscalls()i1["proc.wait"]=function(k1)while true do local j1=d.info(k1)if not j1 then return-1 end if j1.status=="dead"or j1.status=="error"then if j1.termSig then return-j1.termSig end return j1.exitCode or 0 end if os.sleep then os.sleep(0.05)end end end i1["proc.info"]=function(j1)return d.info(j1)end i1["proc.onExit"]=function(j1)d.setExitHook(j1)end i1["proc.spawnFile"]=function(l1,p1,x1)local m1=c.fs if not m1.exists(l1)then return nil,l1..": no such file"end if not m1.canExecute(l1)then return nil,l1..": permission denied"end local y1,w1=m1.open(l1,"r")if not y1 then return nil,l1..": "..tostring(w1)end local t1=y1.readAll()y1.close()local k1={}local o1=t1:match("^#!([^\n]*)")local n1=l1 if o1 then local j1,q1=o1:match("^%s*(%S+)%s*(.-)%s*$")if not j1 then return nil,l1..": empty shebang"end if j1:match("[^/]+$")=="env"then local r1=q1:match("^(%S+)")if not r1 then return nil,l1..": shebang env without program"end q1=q1:sub(#r1+1)j1=r1 end if not m1.exists(j1)then return nil,l1..": shebang interpreter not found: "..j1 end if not m1.canExecute(j1)then return nil,l1..": shebang interpreter not executable: "..j1 end local v1=m1.open(j1,"r")if not v1 then return nil,j1..": permission denied"end t1=v1.readAll()v1.close()k1[0]=j1 local u1=1 for b2 in q1:gmatch("%S+")do k1[u1]=b2;u1=u1+1 end k1[u1]=l1;u1=u1+1 for a2=1,#p1 do k1[u1]=p1[a2];u1=u1+1 end n1=j1 else k1[0]=l1 for z1=1,#p1 do k1[z1]=p1[z1]end end local s1=d.current()return d.spawn(t1,n1,s1.pid,nil,nil,k1,x1)end i1["pipe.create"]=function()return g1.create()end i1["stdio.set"]=function(k1,j1)return d.setStdio(k1,j1)end i1["tty.setFocus"]=function(j1)return s.setFocus(j1)end i1["tty.console"]=function()return s.getFocus()end i1["fs.mount"]=function(j1,l1,k1)return h.mount(j1,l1,k1)end i1["fs.umount"]=function(j1)return h.umount(j1)end i1["fs.mounts"]=function()local j1={}for l1,k1 in ipairs(w.list())do j1[#j1+1]={root=k1.root,device=k1.meta and k1.meta.device,fstype=k1.meta and k1.meta.fstype,uuid=k1.meta and k1.meta.uuid,ro=k1.backend.isReadOnly("")and true or false,}end return j1 end i1["fs.fstypes"]=function()return h.fstypes()end i1["blkdev.list"]=function()return h.list()end i1["fstab.entries"]=function(j1)return f1.read(c.fs,j1)end j.registerSyscalls(i1)s.onSignal=function(k1)local j1=d.tcgetpgrp(s.getFocus())if j1 then d.signalGroup(j1,k1)end end end local function i()pcall(term.setCursorBlink,false)local function j1(l1)return string.format("%x",l1)end local k1={id="console",type="console",mode="term",name="term",device=term,getSize=function()return term.getSize()end,text=function(p1,q1,n1,m1,l1)term.setCursorPos(p1+1,q1+1)if m1 and l1 then local o1=#n1 term.blit(n1,string.rep(j1(m1),o1),string.rep(j1(l1),o1))else term.write(n1)end end,blit=function(p1,q1,l1,n1,m1)term.setCursorPos(p1+1,q1+1)local o1=#l1 term.blit(l1,string.rep(j1(n1 or 0),o1),string.rep(j1(m1 or 0),o1))end,fill=function(l1)term.setBackgroundColor(l1 or 0)term.clear()end,flush=function()end,release=function()end,}b1.register(k1)local i1=s.getFocus()c.registerDevice("console",{writable=true,open=function(l1)return s.open(i1,l1)end,})a("console tty registered -> "..i1.." (/dev/console alias)")end local function m(i1,n1)b.log=a if i1 then b.fs=i1 end b.init(n1)local r1,p1=b.loadAll()if not r1 then return nil,p1 end a("modules loaded from "..n1)local q1,k1=b.loadAliases()if q1 then for s1,l1 in ipairs(peripheral.getNames())do local m1=peripheral.getType(l1)if m1 then local o1,j1=b.use(m1,l1)if not o1 and j1 and j1:find("no module for alias")then elseif not o1 then a("autoload "..m1..": "..tostring(j1))end end end elseif k1 and k1:find("no modules.alias")then a("no modules.alias (drivers not auto-loaded)")end return true end local function r(m1)local l1=m1.rootFstype a("root boot: fstype="..tostring(l1).." root="..tostring(m1.rootPath))local j1,i1 if l1=="ext2"then local q1,r1=e1.mount(m1.blockDevice)if not q1 then a("FATAL: root ext2 mount: "..tostring(r1));return end j1=e1.backend(q1)local k1 for t1,s1 in ipairs(h.list())do if s1.type=="part"and s1.img==m1.blockDevice.path then k1=s1;break end end if k1 then i1={device=k1.node,fstype=k1.fstype,uuid=k1.uuid}else a("root boot: no /dev node for root partition, using virtual device")i1={device=m1.rootPath or"rootfs",fstype="ext2"}end elseif l1=="ccdisk"then j1=w.real(m1.rootPath)i1={device=m1.rootPath,fstype="ccdisk"}else a("FATAL: unknown root fstype "..tostring(l1))return end c.mountDev()j.register()u.mount(k,b.version)i()l()w.mount("/",j1,i1)c.setStdio({read=function(self,...)return read(...)end},{write=function(self,u1)return write(u1)end,writeLine=function(self,u1)return write(u1.."\n")end,flush=function(self)return true end})if not o()then return end local n1="/lib/modules/"..b.version if not c.fs.exists(n1.."/manifest")then a("FATAL: root has no module dir "..n1)return end local p1,o1=m(c.fs,n1)if not p1 then a("FATAL: module load failed: "..tostring(o1))return end e()f()a1.mount()t(n,l1)end local c1={}function c1.boot()g=fs.open("/delin.log","a")k=os.epoch("utc")d.log=v a("Delin OS "..b.version.." boot")a("craftos="..os.version())if __boot_info then return r(__boot_info)end local m1,k1=pcall(z)if not m1 then a("FATAL: setupVfs failed: "..tostring(k1))return end a("vfs ready")l()i()if not o()then return end local l1=q()if l1 then local o1,n1=m(nil,l1)if not o1 then a("FATAL: module load failed: "..tostring(n1))return end else a("no module dir found (modules skipped)")end local j1=table.concat(c.devices(),",")local i1={}for p1 in pairs(b.syscalls())do i1[#i1+1]=p1 end a("devices="..j1)a("syscalls="..table.concat(i1,","))e()f()a1.mount()t(n,"")end return c1 end __chunks["kernel.devdisk"]=function()local _ENV=setmetatable({require=__require},{__index=_G})local h=require("kernel.vfs")local e=require("kernel.vfs_api")local j=require("kernel.manifest")local a={}local b={}function a.registerFstype(o,p)b[o]=p end function a.fstypes()local o={}for p in pairs(b)do o[#o+1]=p end table.sort(o)return o end local c={}local d={}local function i(o)local p=""while o>0 do local q=(o-1)%26 p=string.char(97+q)..p o=math.floor((o-1)/26)end return p end local function n()local p={}for r,o in ipairs(peripheral.getNames())do if disk.hasData(o)then local q=disk.getMountPath(o)if not q then error("devdisk: "..o..": disk.hasData but no mount path",0)end p[#p+1]={side=o,mountPath=q,diskId=disk.getID(o),label=disk.getLabel(o),}end end table.sort(p,function(s,t)if s.diskId and t.diskId then if s.diskId~=t.diskId then return s.diskId<t.diskId end elseif s.diskId~=t.diskId then return s.diskId~=nil end return s.side<t.side end)return p end local function f(o)local q=fs.open(o.."/parts/manifest","r")if not q then return nil end local p=q.readAll()q.close()return j.parse(p)end function a.scan()local p={}for w,s in ipairs(n())do local o="sd"..i(w)local q=s.diskId and tostring(s.diskId)or nil p[#p+1]={name=o,node="/dev/"..o,type="disk",fstype="ccdisk",uuid=q,diskId=s.diskId,index=w,side=s.side,label=s.label,mountPath=s.mountPath,size=fs.getCapacity(s.mountPath),}local x=f(s.mountPath)if x then for u,v in ipairs(x.partitions)do local r=v.path if r:sub(1,1)~="/"then r="/"..r end local t=s.mountPath..r p[#p+1]={name=o..u,node="/dev/"..o..u,type="part",fstype=(v.fstype~=""and v.fstype)or"ext2",uuid=q and(q.."-"..u)or nil,diskId=s.diskId,index=w,part=u,role=v.role,side=s.side,img=t,size=fs.exists(t)and fs.getSize(t)or nil,}end end end return p end local function m(r,o)local p,q=fs.open(r.img,(o and o:find("w"))and"r+"or"r")if not p then return nil,q end return{read=function(s,t)return p.read((type(s)=="table")and t or s)end,readLine=function(s)return p.readLine((type(s)=="table")and nil or s)end,readAll=function()return p.readAll()end,write=function(s,t)return p.write((type(s)=="table")and t or s)end,close=function()return p.close()end,}end local function k(o,p)local q=c[o]if not q then return nil,"/dev/"..o..": no such device"end if q.type~="part"then return nil,"/dev/"..o..": CC native filesystem (ccdisk) — mount it, no byte stream"end return m(q,p)end function a.refresh()local q=a.scan()c={}for s,r in ipairs(q)do c[r.name]=r if r.type=="disk"then c["ccdisk"..(r.index-1)]=r end end for p in pairs(d)do if not c[p]then e.unregisterDevice(p)d[p]=nil end end for o in pairs(c)do e.registerDevice(o,{writable=true,open=function(t)return k(o,t)end,})d[o]=true end return q end function a.list()local q=a.refresh()local o={}for u,r in ipairs(h.list())do local p=r.meta and r.meta.device if p then o[p]=o[p]or{}o[p][#o[p]+1]=r.root end end for t,s in ipairs(q)do s.mounted=o[s.node]or{}end return q end function a.find(o)if type(o)~="string"or o==""then return nil,"empty device"end if o:sub(1,5)=="UUID="then local q=o:sub(6)if q==""then return nil,"UUID=: empty uuid"end for t,r in ipairs(a.list())do if r.uuid==q then return r end end return nil,o..": no such device"end a.refresh()local p=o:gsub("^/dev/","")local s=c[p]if not s then return nil,"/dev/"..p..": no such device"end return s end local function l(o)if o.type=="part"then return{img=o.img}end return{ccpath=o.mountPath}end local function g(o,u,s)local p,w,v=h.resolve(o)if not p then return nil,o..": "..tostring(v)end if not p.toReal then return nil,o..": not on a real filesystem"end local t=p.toReal(w)local x=(s=="ccdisk")and{ccpath=t}or{img=t}local r=b[s]if not r then return nil,"unknown fstype: "..s end local z,y,q=pcall(r,x,u)if not z then return nil,o..": "..tostring(y)end if not y then return nil,o..": "..tostring(q)end q=q or{}q.device,q.fstype=o,s h.mount(u,y,q)return true,{device=o,fstype=s}end function a.mountLocal(o,t,s)if not e.fs.exists(o)then return nil,o..": file not found"end local r=s or"ext2"local u={img=o}local q=b[r]if not q then return nil,"unknown fstype: "..r end local w,v,p=pcall(q,u,t)if not w then return nil,o..": "..tostring(v)end if not v then return nil,o..": "..tostring(p)end p=p or{}p.device,p.fstype=o,r h.mount(t,v,p)return true,{device=o,fstype=r}end function a.mount(o,t,u)if not e.fs.isDir(t)then return nil,t..": mount point does not exist"end local s=o:sub(1,5)=="UUID="or o:sub(1,5)=="/dev/"or not o:find("/",1,true)if not s then return g(o,t,u or"ext2")end local v,w=a.find(o)if not v then return nil,w end local q=u or v.fstype if q~=v.fstype then return nil,v.node.." is "..v.fstype..", not "..q end local r=b[q]if not r then return nil,"unknown fstype: "..q.." (module not loaded?)"end local y,x,p=pcall(r,l(v),t)if not y then return nil,v.node..": "..tostring(x)end if not x then return nil,v.node..": "..tostring(p)end p=p or{}p.device,p.fstype,p.uuid=v.node,q,v.uuid h.mount(t,x,p)return true,{device=v.node,fstype=q,uuid=v.uuid}end function a.umount(o)for q,p in ipairs(h.list())do if p.root==o then h.unmount(o)if p.meta and p.meta.cleanup then p.meta.cleanup()end return true end end return nil,o..": not mounted"end return a end __chunks["kernel.display"]=function()local _ENV=setmetatable({require=__require},{__index=_G})local d=require("kernel.vfs_api")local e=require("kernel.tty")local f=require("kernel.fb")local a={}local b={}local c={}function a.register(g)b[g.id]=g local i={}local h,j=e.registerDevice(g)d.registerDevice(h,j)i.tty=h if g.mode~="term"and g.setPixel then local l,k=f.registerDevice(g)d.registerDevice(l,k)i.fb=l end c[g.id]=i return g.id end function a.unregister(i)local h=b[i]if h and h.release then pcall(h.release)end b[i]=nil local g=c[i]if g then if g.tty then d.unregisterDevice(g.tty)end if g.fb then d.unregisterDevice(g.fb)end end c[i]=nil end function a.get(g)return b[g]end function a.list()local g={}for h,i in pairs(b)do g[#g+1]=h end return g end function a.byName(h)for i,g in pairs(b)do if g.name==h then return g end end end function a.resize(h)local g=c[h]if not g then return false end if g.tty then e.resize(g.tty)end if g.fb then f.resize(g.fb)end return true end return a end __chunks["kernel.ext2"]=function()local _ENV=setmetatable({require=__require},{__index=_G})local a={}local d1=nil pcall(function()d1=require("kernel.process")end)local p1=require("kernel.fifo")local function q()if not d1 then return{uid=0,gid=0}end return d1.current()end local function o1(s1,q1)local t1,r1=0,1 for u1=1,12 do if s1%2==1 and q1%2==0 then t1=t1+r1 end s1=math.floor(s1/2);q1=math.floor(q1/2);r1=r1*2 end return t1 end local c1 local function f(q1,s1,t1,r1)if s1==0 then return true end local u1=(s1==q1.uid)and 6 or((t1==q1.gid)and 3 or 0)local v1=math.floor(q1.perms/(2^u1))%8 return v1%(r1*2)>=r1 end local function g1(q1)local r1=q1%512 return(r1%2)==1 or(math.floor(r1/8)%2)==1 or(math.floor(r1/64)%2)==1 end local function p(t1,q1)local r1,s1=t1:byte(q1+1,q1+2);return r1+s1*256 end local function j(v1,q1)local r1,s1,t1,u1=v1:byte(q1+1,q1+4);return r1+s1*256+t1*65536+u1*16777216 end local function v(q1)return string.char(q1%256,math.floor(q1/256)%256)end local function y(q1)return string.char(q1%256,math.floor(q1/256)%256,math.floor(q1/65536)%256,math.floor(q1/16777216)%256)end local function g(r1,q1,s1)return r1:sub(1,q1)..v(s1)..r1:sub(q1+3)end local function d(r1,q1,s1)return r1:sub(1,q1)..y(s1)..r1:sub(q1+5)end local function c(r1,q1)return r1.bd.read(q1*r1.blockSize,r1.blockSize)end local function b(s1,q1,r1)return s1.bd.write(q1*s1.blockSize,r1)end local b1,e,t,m=0x1000,0x4000,0x8000,0xA000 local l1,w,m1,k1,j1,h1,i1,n1=1,2,7,3,4,5,6,0 local function u(q1)return math.floor(q1/0x1000)*0x1000 end local function e1(q1)return q1%0x1000 end c1=function(q1)if u(q1)==m then return q1 end local r1=q().umask or tonumber("022",8)return u(q1)+o1(e1(q1),r1)end local function s(q1)if q1==e then return w end if q1==t then return l1 end if q1==m then return m1 end if q1==0x2000 then return k1 end if q1==0x6000 then return j1 end if q1==0x1000 then return h1 end if q1==0xC000 then return i1 end return n1 end local function h(s1,r1)local q1=s1.bd.read(s1.gdtOffset+r1*32,32)return{blockBitmap=j(q1,0),inodeBitmap=j(q1,4),inodeTable=j(q1,8),freeBlocks=p(q1,12),freeInodes=p(q1,14),}end local function l(q1,t1)local r1=math.floor((t1-1)/q1.inodesPerGroup)local s1=(t1-1)%q1.inodesPerGroup local u1=h(q1,r1)return u1.inodeTable*q1.blockSize+s1*q1.inodeSize end local function f1(q1,r1)return q1.bd.read(l(q1,r1),q1.inodeSize)end function a.mount(v1)local r1=v1.read(1024,1024)if not r1 or#r1<1024 then return nil,"cannot read superblock"end if p(r1,56)~=0xEF53 then return nil,"not EXT2"end local t1=j(r1,24)local q1=1024*2^t1 local s1=j(r1,0)local u1={bd=v1,blockSize=q1,inodes=s1,blocks=j(r1,4),rBlocks=j(r1,8),firstDataBlock=j(r1,20),inodesPerGroup=j(r1,40),blocksPerGroup=j(r1,32),inodeSize=p(r1,88)or 128,firstIno=j(r1,84),gdtOffset=(q1==1024)and(2*q1)or(1*q1),}u1.numGroups=math.max(math.ceil((u1.blocks-u1.firstDataBlock)/u1.blocksPerGroup),math.ceil(s1/u1.inodesPerGroup))return u1 end function a.readInode(s1,u1)local v1=math.floor((u1-1)/s1.inodesPerGroup)local w1=(u1-1)%s1.inodesPerGroup local x1=h(s1,v1)local r1=x1.inodeTable*s1.blockSize+w1*s1.inodeSize local q1=s1.bd.read(r1,s1.inodeSize)if not q1 then return nil end local t1={ino=u1,mode=p(q1,0),uid=p(q1,2),sizeLo=j(q1,4),gid=p(q1,24),links=p(q1,26),blocks=j(q1,28),sizeHigh=j(q1,108),}t1.size=t1.sizeHigh*4294967296+t1.sizeLo t1.type=u(t1.mode)t1.perms=e1(t1.mode)t1.mtime=j(q1,16)t1.ptrs={}for y1=0,14 do t1.ptrs[y1+1]=j(q1,40+y1*4)end return t1 end function a.writeInode(t1,r1)local q1=string.rep("\0",t1.inodeSize)q1=g(q1,0,r1.mode)q1=g(q1,2,r1.uid or 0)local s1=r1.size or 0 q1=d(q1,4,s1%4294967296)q1=d(q1,8,r1.atime or 0)q1=d(q1,12,r1.ctime or 0)q1=d(q1,16,r1.mtime or 0)q1=g(q1,24,r1.gid or 0)q1=g(q1,26,r1.links or 1)q1=d(q1,28,r1.blocks or 0)for u1=1,15 do q1=d(q1,40+(u1-1)*4,r1.ptrs[u1]or 0)end q1=d(q1,108,math.floor(s1/4294967296))return t1.bd.write(l(t1,r1.ino),q1)end local function x(q1)return j(q1.bd.read(1024,1024),12)end local function i(u1,w1,r1,s1,t1)local v1=u1.bd.read(1024,u1.blockSize)v1=d(v1,12,(j(v1,12)or 0)+r1)v1=d(v1,16,(j(v1,16)or 0)+s1)u1.bd.write(1024,v1)local q1=u1.bd.read(u1.gdtOffset+w1*32,32)q1=g(q1,12,(p(q1,12)or 0)+r1)q1=g(q1,14,(p(q1,14)or 0)+s1)if t1 and t1~=0 then q1=g(q1,16,(p(q1,16)or 0)+t1)end u1.bd.write(u1.gdtOffset+w1*32,q1)end function a.allocBlock(r1)if x(r1)<=r1.rBlocks then return nil end local x1=r1.blocksPerGroup local z1=r1.firstDataBlock for s1=0,r1.numGroups-1 do local a2=h(r1,s1)if a2.freeBlocks>0 then local q1=c(r1,a2.blockBitmap)local u1=z1+s1*x1 local v1=math.min(x1,r1.blocks-u1)-1 for t1=0,v1 do local b2=q1:byte(math.floor(t1/8)+1)or 0 if math.floor(b2/2^(t1%8))%2==0 then local y1=math.floor(t1/8)+1 q1=q1:sub(1,y1-1)..string.char(b2+2^(t1%8))..q1:sub(y1+1)b(r1,a2.blockBitmap,q1)i(r1,s1,-1,0)local w1=u1+t1 b(r1,w1,string.rep("\0",r1.blockSize))return w1 end end end end return nil end function a.freeBlock(r1,v1)if v1<r1.firstDataBlock then return end local w1=v1-r1.firstDataBlock local s1=math.floor(w1/r1.blocksPerGroup)local t1=w1%r1.blocksPerGroup local x1=h(r1,s1)local q1=c(r1,x1.blockBitmap)local u1=math.floor(t1/8)+1 local y1=q1:byte(u1)or 0 if math.floor(y1/2^(t1%8))%2==1 then y1=y1-2^(t1%8)q1=q1:sub(1,u1-1)..string.char(y1)..q1:sub(u1+1)b(r1,x1.blockBitmap,q1)i(r1,s1,1,0)end end function a.allocInode(t1,v1,c2,b2)local y1=t1.inodesPerGroup for r1=0,t1.numGroups-1 do local a2=h(t1,r1)if a2.freeInodes>0 then local q1=c(t1,a2.inodeBitmap)for s1=(t1.firstIno-1),(y1-1)do local d2=q1:byte(math.floor(s1/8)+1)or 0 if math.floor(d2/2^(s1%8))%2==0 then local z1=math.floor(s1/8)+1 q1=q1:sub(1,z1-1)..string.char(d2+2^(s1%8))..q1:sub(z1+1)b(t1,a2.inodeBitmap,q1)local x1=r1*y1+s1+1 local w1=math.floor(os.epoch("utc")/1000)local u1={ino=x1,mode=v1,uid=c2 or 0,gid=b2 or 0,links=1,size=0,blocks=0,atime=w1,ctime=w1,mtime=w1,ptrs={}}for e2=1,15 do u1.ptrs[e2]=0 end a.writeInode(t1,u1)i(t1,r1,0,-1,u(v1)==e and 1 or 0)return x1 end end end end return nil end function a.freeInode(r1,t1)local s1=math.floor((t1-1)/r1.inodesPerGroup)local v1=(t1-1)%r1.inodesPerGroup local y1=h(r1,s1)local q1=c(r1,y1.inodeBitmap)local w1=math.floor(v1/8)+1 local z1=q1:byte(w1)or 0 if math.floor(z1/2^(v1%8))%2==1 then local u1=a.readInode(r1,t1)local x1=u1 and u1.type==e z1=z1-2^(v1%8)q1=q1:sub(1,w1-1)..string.char(z1)..q1:sub(w1+1)b(r1,y1.inodeBitmap,q1)i(r1,s1,0,1,x1 and-1 or 0)r1.bd.write(l(r1,t1),string.rep("\0",r1.inodeSize))end end local function n(q1)return math.floor(q1.blockSize/4)end function a.getBlock(u1,r1,q1)local s1=n(u1)if q1<12 then return r1.ptrs[q1+1]end q1=q1-12 if q1<s1 then if r1.ptrs[13]==0 then return 0 end return j(c(u1,r1.ptrs[13]),q1*4)end q1=q1-s1 if q1<s1*s1 then if r1.ptrs[14]==0 then return 0 end local t1=c(u1,r1.ptrs[14])local v1=j(t1,math.floor(q1/s1)*4)if v1==0 then return 0 end return j(c(u1,v1),(q1%s1)*4)end return 0 end local function o(r1,q1)q1.blocks=q1.blocks+math.floor(r1.blockSize/512)end function a.ensureBlock(r1,q1,s1)local w1=n(r1)if s1<12 then if q1.ptrs[s1+1]==0 then q1.ptrs[s1+1]=a.allocBlock(r1)if q1.ptrs[s1+1]then o(r1,q1)end end return q1.ptrs[s1+1]end s1=s1-12 if s1<w1 then if q1.ptrs[13]==0 then q1.ptrs[13]=a.allocBlock(r1);if not q1.ptrs[13]then return nil end o(r1,q1);b(r1,q1.ptrs[13],string.rep("\0",r1.blockSize))end local x1=c(r1,q1.ptrs[13])local y1=j(x1,s1*4)if y1==0 then y1=a.allocBlock(r1);if not y1 then return nil end x1=d(x1,s1*4,y1);b(r1,q1.ptrs[13],x1);o(r1,q1)end return y1 end s1=s1-w1 if s1<w1*w1 then if q1.ptrs[14]==0 then q1.ptrs[14]=a.allocBlock(r1);if not q1.ptrs[14]then return nil end o(r1,q1);b(r1,q1.ptrs[14],string.rep("\0",r1.blockSize))end local u1=c(r1,q1.ptrs[14])local a2=math.floor(s1/w1)*4 local v1=j(u1,a2)if v1==0 then v1=a.allocBlock(r1);if not v1 then return nil end u1=d(u1,a2,v1);b(r1,q1.ptrs[14],u1);o(r1,q1)b(r1,v1,string.rep("\0",r1.blockSize))end local t1=c(r1,v1)local b2=(s1%w1)*4 local z1=j(t1,b2)if z1==0 then z1=a.allocBlock(r1);if not z1 then return nil end t1=d(t1,b2,z1);b(r1,v1,t1);o(r1,q1)end return z1 end return nil end local function r(r1,q1)if(q1.blocks or 0)==0 then return 0 end return math.ceil((q1.size or 0)/r1.blockSize)end function a.freeBlocksOfInode(r1,q1)local s1=r(r1,q1)for w1=0,s1-1 do local t1=a.getBlock(r1,q1,w1)if t1 and t1~=0 then a.freeBlock(r1,t1)end end if(q1.blocks or 0)==0 then return end local x1=n(r1)if q1.ptrs[13]~=0 then a.freeBlock(r1,q1.ptrs[13])end if q1.ptrs[14]~=0 then local u1=c(r1,q1.ptrs[14])for y1=0,x1-1 do local v1=j(u1,y1*4);if v1~=0 then a.freeBlock(r1,v1)end end a.freeBlock(r1,q1.ptrs[14])end end function a.readDir(a2,u1)local t1={}if u1.type~=e then return nil end local z1=math.ceil((u1.size or 0)/a2.blockSize)for b2=0,z1-1 do local q1=a.getBlock(a2,u1,b2)if not q1 or q1==0 then break end local s1=c(a2,q1)local r1=0 while r1<#s1 do local w1=j(s1,r1)local x1=p(s1,r1+4)if x1==0 then break end local v1=s1:byte(r1+7)local y1=s1:byte(r1+8)if w1~=0 and v1>0 then t1[#t1+1]={ino=w1,name=s1:sub(r1+9,r1+8+v1),fileType=y1}end r1=r1+x1 end end return t1 end local function z(q1)return q1+((4-(q1%4))%4)end local function k(t1,r1,s1)local q1=a.readDir(t1,r1)if not q1 then return nil end for v1,u1 in ipairs(q1)do if u1.name==s1 then return u1 end end return nil end function a.lookup(t1,r1)r1=r1:gsub("^/+",""):gsub("/+$","")local q1=a.readInode(t1,2)if r1==""then return q1 end for s1 in r1:gmatch("[^/]+")do if s1=="."then elseif s1==".."then if q1.type==e then local u1=k(t1,q1,"..")if u1 then q1=a.readInode(t1,u1.ino)end end else if q1.type~=e then return nil end local v1=k(t1,q1,s1)if not v1 then return nil end q1=a.readInode(t1,v1.ino)end end return q1 end local function a1(t1,q1)local s1=q1.size if s1<=60 then local u1=f1(t1,q1.ino)return u1:sub(41,40+s1)end local r1=a.getBlock(t1,q1,0)if not r1 or r1==0 then return nil end return c(t1,r1):sub(1,s1)end function a.readFile(w1,s1)if s1.type==m then return a1(w1,s1)end if s1.type~=t then return nil end local v1={}local q1=s1.size local u1=0 while q1>0 do local r1=a.getBlock(w1,s1,u1)if not r1 or r1==0 then break end local t1=c(w1,r1)if not t1 then break end v1[#v1+1]=t1:sub(1,math.min(#t1,q1))q1=q1-#t1 u1=u1+1 end return table.concat(v1)end function a.addDirEntry(y1,s1,e2,w1,x1)local t1=#e2 local l2=z(8+t1)local c2=math.ceil((s1.size or 0)/y1.blockSize)for m2=0,c2-1 do local u1=a.getBlock(y1,s1,m2)if u1 then local r1=c(y1,u1)local v1=0 while v1<#r1 do local q1=p(r1,v1+4)if q1==0 then break end if j(r1,v1)==0 then if q1>=l2 then local j2=y(w1)..v(q1)..string.char(t1,x1)..e2..string.rep("\0",q1-(8+t1))r1=r1:sub(1,v1)..j2..r1:sub(v1+q1+1)b(y1,u1,r1)return true end else local d2=r1:byte(v1+7)local b2=z(8+d2)local a2=q1-b2 if a2>=l2 then r1=g(r1,v1+4,b2)local f2=v1+b2 local i2=y(w1)..v(a2)..string.char(t1,x1)..e2..string.rep("\0",a2-(8+t1))r1=r1:sub(1,f2)..i2..r1:sub(f2+a2+1)b(y1,u1,r1)return true end end v1=v1+q1 end end end local z1=c2 if not a.ensureBlock(y1,s1,z1)then return nil,"no block"end local g2=a.getBlock(y1,s1,z1)if s1.size==0 then s1.size=y1.blockSize end local h2=s1.size if h2<=z1*y1.blockSize then s1.size=(z1+1)*y1.blockSize end a.writeInode(y1,s1)local k2=y(w1)..v(y1.blockSize)..string.char(t1,x1)..e2..string.rep("\0",y1.blockSize-(8+t1))b(y1,g2,k2)return true end function a.create(s1,v1,y1,t1,a2,x1)local r1=a.lookup(s1,v1)if not r1 or r1.type~=e then return nil,"parent not a dir"end if k(s1,r1,y1)then return nil,"exists"end local e2=q()a2=a2 or e2.uid x1=x1 or e2.gid t1=c1(t1)local u1=a.allocInode(s1,t1,a2,x1)if not u1 then return nil,"alloc inode failed"end local q1=a.readInode(s1,u1)local z1=math.floor(os.epoch("utc")/1000)q1.mtime=z1;q1.ctime=z1;q1.atime=z1 if u(t1)==e then local w1=a.allocBlock(s1)if not w1 then return nil,"no block for dir"end q1.ptrs[1]=w1 q1.size=s1.blockSize q1.blocks=q1.blocks+math.floor(s1.blockSize/512)q1.links=2 local c2=y(u1)..v(12)..string.char(1,w).."."..string.rep("\0",3)local d2=y(r1.ino)..v(s1.blockSize-12)..string.char(2,w)..".."..string.rep("\0",2)b(s1,w1,c2..d2)end a.writeInode(s1,q1)a.addDirEntry(s1,r1,y1,u1,s(u(t1)))if u(t1)==e then local b2=a.readInode(s1,r1.ino)b2.links=b2.links+1 a.writeInode(s1,b2)end return u1 end function a.writeFile(u1,a2,t1)local q1=a.readInode(u1,a2)if not q1 or(q1.type~=t and q1.type~=m)then return nil,"not a regular file"end local r1=u1.blockSize local v1=r(u1,q1)local s1=math.ceil(#t1/r1)for d2=0,s1-1 do local y1=a.ensureBlock(u1,q1,d2)if not y1 then return nil,"no block"end local z1=d2*r1+1 local x1=t1:sub(z1,z1+r1-1)b(u1,y1,x1)end local b2=n(u1)for c2=s1,v1-1 do local w1=a.getBlock(u1,q1,c2)if w1 and w1~=0 then a.freeBlock(u1,w1)if c2<12 then q1.ptrs[c2+1]=0 end q1.blocks=math.max(0,q1.blocks-math.floor(r1/512))end end if s1<=12 and q1.ptrs[13]~=0 then a.freeBlock(u1,q1.ptrs[13]);q1.ptrs[13]=0 q1.blocks=math.max(0,q1.blocks-math.floor(r1/512))end if s1<=12+b2 and q1.ptrs[14]~=0 then a.freeBlock(u1,q1.ptrs[14]);q1.ptrs[14]=0 q1.blocks=math.max(0,q1.blocks-math.floor(r1/512))end q1.size=#t1 q1.mtime=math.floor(os.epoch("utc")/1000)a.writeInode(u1,q1)return true end function a.setSymlink(t1,s1,r1)local q1=a.readInode(t1,s1)if not q1 or q1.type~=m then return nil,"not a symlink"end if#r1>60 then return a.writeFile(t1,s1,r1)end local z1=r1..string.rep("\0",60-#r1)q1.ptrs={}for y1=0,14 do local u1,v1,w1,x1=z1:byte(y1*4+1,y1*4+4)q1.ptrs[y1+1]=u1+v1*256+w1*65536+x1*16777216 end q1.size=#r1 q1.blocks=0 q1.mtime=math.floor(os.epoch("utc")/1000)q1.ctime=q1.mtime return a.writeInode(t1,q1)end function a.getSymlink(r1,s1)local q1=a.readInode(r1,s1)if not q1 then return nil,"no such file"end if q1.type~=m then return nil,"not a symlink"end local t1=a1(r1,q1)if not t1 then return nil,"cannot read symlink"end return t1 end function a.link(v1,w1,r1)local u1=a.lookup(v1,w1)if not u1 then return nil,"no such file"end if u1.type==e then return nil,"hard link to a directory is not allowed"end local x1=r1:match("^(.*)/[^/]*$")or"/"local t1=r1:match("([^/]*)$")or r1 if t1==""then return nil,"invalid path"end local q1=a.lookup(v1,x1)if not q1 or q1.type~=e then return nil,"parent not a dir"end if k(v1,q1,t1)then return nil,"file exists"end local z1=q()if not(f(q1,z1.uid,z1.gid,2)and f(q1,z1.uid,z1.gid,1))then return nil,"permission denied (dir)"end local a2,y1=a.addDirEntry(v1,q1,t1,u1.ino,s(u1.type))if not a2 then return nil,y1 end local s1=a.readInode(v1,u1.ino)s1.links=(s1.links or 1)+1 s1.ctime=math.floor(os.epoch("utc")/1000)return a.writeInode(v1,s1)end function a.appendFile(v1,b2,u1)if u1==""then return true end local r1=a.readInode(v1,b2)if not r1 or(r1.type~=t and r1.type~=m)then return nil,"not a regular file"end local q1=v1.blockSize local s1=r1.size or 0 local z1=1 while z1<=#u1 do local a2=math.floor(s1/q1)local w1=a.ensureBlock(v1,r1,a2)if not w1 then return nil,"no block"end local x1=s1%q1 local t1=u1:sub(z1,z1+(q1-x1)-1)if x1==0 and#t1==q1 then b(v1,w1,t1)else local y1=c(v1,w1)or""b(v1,w1,y1:sub(1,x1)..t1..y1:sub(x1+#t1+1))end s1=s1+#t1 z1=z1+#t1 end r1.size=s1 r1.mtime=math.floor(os.epoch("utc")/1000)a.writeInode(v1,r1)return true end function a.removeDirEntry(a2,x1,z1)local y1=math.ceil((x1.size or 0)/a2.blockSize)for b2=0,y1-1 do local r1=a.getBlock(a2,x1,b2)if r1 then local s1=c(a2,r1)local v1,u1,w1=0,nil,0 while v1<#s1 do local q1=p(s1,v1+4)if q1==0 then break end local t1=s1:byte(v1+7)if t1==#z1 and s1:sub(v1+9,v1+8+t1)==z1 then if not u1 then return nil,"cannot remove first dir entry"end s1=g(s1,u1+4,w1+q1)b(a2,r1,s1)return true end u1,w1=v1,q1 v1=v1+q1 end end end return false end function a.delete(s1,u1,v1)local r1=a.lookup(s1,u1)if not r1 or r1.type~=e then return nil,"parent not a dir"end local t1=k(s1,r1,v1)if not t1 then return nil,"no such entry"end local y1,x1=a.removeDirEntry(s1,r1,v1)if not y1 then return nil,x1 end local q1=a.readInode(s1,t1.ino)if q1 then q1.links=math.max(0,q1.links-1)local w1=(q1.type==e)and(q1.links<=1)or(q1.links<=0)if w1 then if q1.type==b1 then p1.forget(s1,q1.ino)end a.freeBlocksOfInode(s1,q1)a.freeInode(s1,q1.ino)else a.writeInode(s1,q1)end if q1.type==e then r1.links=math.max(2,r1.links-1)a.writeInode(s1,r1)end end return true end function a.chmod(t1,r1,s1)local q1=a.lookup(t1,r1)if not q1 then return nil,"no such file: "..tostring(r1)end q1.mode=q1.type+(s1%0x1000)a.writeInode(t1,q1)return true end function a.chown(u1,t1,s1,r1)local q1=a.lookup(u1,t1)if not q1 then return nil,"no such file"end if s1 then q1.uid=s1 end if r1 then q1.gid=r1 end a.writeInode(u1,q1)return true end function a.backend(q1)local function r1(s1)return{size=s1.size,isDir=s1.type==e,isReadOnly=false,mode=s1.mode,uid=s1.uid,gid=s1.gid,ino=s1.ino,links=s1.links,mtime=s1.mtime,kind=s1.type==e and"dir"or(s1.type==t and"file"or(s1.type==m and"symlink"or(s1.type==b1 and"fifo"or"device"))),}end return{kind="virtual",isReadOnly=function()return false end,list=function(u1)local s1=a.lookup(q1,u1 or"/")if not s1 or s1.type~=e then return nil end local w1=q()if not f(s1,w1.uid,w1.gid,4)then return nil,"permission denied"end local t1={}for x1,v1 in ipairs(a.readDir(q1,s1))do if v1.name~="."and v1.name~=".."then t1[#t1+1]=v1.name end end return t1 end,exists=function(s1)return a.lookup(q1,s1)~=nil end,isDir=function(s1)local t1=a.lookup(q1,s1);return t1 and t1.type==e or false end,isFile=function(s1)local t1=a.lookup(q1,s1);return t1 and t1.type==t or false end,attributes=function(s1)local t1=a.lookup(q1,s1);return t1 and r1(t1)or nil end,symlink=function(w1,v1)local u1=v1:match("^(.*)/[^/]*$")or"/"local t1=v1:match("([^/]*)$")or v1 if t1==""then return nil,"invalid path"end local a2=q()local s1=a.lookup(q1,u1)if not s1 or s1.type~=e then return nil,"parent not a dir"end if not(f(s1,a2.uid,a2.gid,2)and f(s1,a2.uid,a2.gid,1))then return nil,"permission denied (dir)"end local x1,z1=a.create(q1,u1,t1,m+tonumber("777",8))if not x1 then return nil,z1 end local b2,y1=a.setSymlink(q1,x1,w1)if not b2 then return nil,y1 end return true end,readlink=function(s1)local t1=a.lookup(q1,s1)if not t1 then return nil,"no such file"end return a.getSymlink(q1,t1.ino)end,link=function(t1,s1)return a.link(q1,t1,s1)end,mkfifo=function(v1,w1)local u1=v1:match("^(.*)/[^/]*$")or"/"local t1=v1:match("([^/]*)$")or v1 if t1==""then return nil,"invalid path"end local a2=q()local s1=a.lookup(q1,u1)if not s1 or s1.type~=e then return nil,"parent not a dir"end if not(f(s1,a2.uid,a2.gid,2)and f(s1,a2.uid,a2.gid,1))then return nil,"permission denied (dir)"end local x1=e1(w1 or tonumber("666",8))local z1,y1=a.create(q1,u1,t1,b1+x1)if not z1 then return nil,y1 end return true end,getSize=function(s1)local t1=a.lookup(q1,s1);return t1 and t1.size or 0 end,getDrive=function()return"ext2"end,getFreeSpace=function()return math.max(0,x(q1)-q1.rBlocks)*q1.blockSize end,getCapacity=function()return q1.blocks*q1.blockSize end,open=function(y1,x1)local z1=a.lookup(q1,y1)local d2=q()if z1 and z1.type==b1 then local j2=x1 and(x1:find("w")or x1:find("a"))local m2=j2 and 2 or 4 if not f(z1,d2.uid,d2.gid,m2)then return nil,"permission denied (fifo)"end return p1.open(q1,z1.ino,x1 or"r")end local function w1(q2)local p2=a.lookup(q1,q2)if p2 and not(f(p2,d2.uid,d2.gid,2)and f(p2,d2.uid,d2.gid,1))then return false end return true end if x1 and x1:find("w")then if not z1 then local f2=y1:match("^(.*)/[^/]*$")or"/"local i2=y1:match("([^/]*)$")or y1 if not w1(f2)then return nil,"permission denied (dir)"end local l2,o2=a.create(q1,f2,i2,0x81A4)if not l2 then return nil,o2 end z1=a.readInode(q1,l2)end if z1.type==e then return nil,"is a directory"end if not f(z1,d2.uid,d2.gid,2)then return nil,"permission denied (file)"end a.writeFile(q1,z1.ino,"")local v1={}local function b2()return a.writeFile(q1,z1.ino,table.concat(v1))end local function e2()local p2=0;for q2=1,#v1 do p2=p2+#v1[q2]end;return p2 end local function c2(q2,s2)s2=s2 or 0 local r2=e2()local p2 if q2==nil or q2=="cur"then p2=r2+s2 elseif q2=="set"then p2=s2 elseif q2=="end"then p2=r2+s2 else return nil,"bad whence"end if p2<0 then return nil,"negative seek"end if p2<r2 then return nil,"cannot seek backwards on a buffered write handle"end if p2>r2 then v1[#v1+1]=string.rep("\0",p2-r2)end return p2 end return{write=function(self,p2)if p2==nil then p2=self end;v1[#v1+1]=p2;return#p2 end,writeLine=function(self,p2)if p2==nil then p2=self end;v1[#v1+1]=p2.."\n";return#p2+1 end,flush=b2,close=b2,seek=function(p2,q2,r2)if type(p2)=="table"then return c2(q2,r2)end return c2(p2,q2)end,}end if x1 and x1:find("a")then if not z1 then local g2=y1:match("^(.*)/[^/]*$")or"/"local h2=y1:match("([^/]*)$")or y1 if not w1(g2)then return nil,"permission denied (dir)"end local k2,n2=a.create(q1,g2,h2,0x81A4)if not k2 then return nil,n2 end z1=a.readInode(q1,k2)end if z1.type==e then return nil,"is a directory"end if not f(z1,d2.uid,d2.gid,2)then return nil,"permission denied (file)"end local u1={}local function a2()if#u1==0 then return true end local p2=table.concat(u1)u1={}return a.appendFile(q1,z1.ino,p2)end return{write=function(self,p2)if p2==nil then p2=self end;u1[#u1+1]=p2;return#p2 end,writeLine=function(self,p2)if p2==nil then p2=self end;u1[#u1+1]=p2.."\n";return#p2+1 end,flush=a2,close=a2,seek=function(r2,s2,u2)local p2=(type(r2)=="table")and s2 or r2 local q2=(type(r2)=="table")and u2 or s2 if(p2==nil or p2=="cur")and(q2==nil or q2==0)then local t2=0;for v2=1,#u1 do t2=t2+#u1[v2]end return(z1.size or 0)+t2 end return nil,"append handle only supports seek(0) to query the position"end,}end if not z1 then return nil,"no such file"end if z1.type==e then return nil,"is a directory"end if not f(z1,d2.uid,d2.gid,4)then return nil,"permission denied (read)"end local s1=a.readFile(q1,z1)local t1=0 return{readAll=function()t1=#s1;return s1 end,read=function(q2,r2)local p2 if type(q2)=="number"then p2=q2 elseif type(q2)=="table"and type(r2)=="number"then p2=r2 end if t1>=#s1 then return nil end if p2==nil then local t2=s1:sub(t1+1);t1=#s1;return t2 end local s2=s1:sub(t1+1,t1+p2)t1=t1+#s2 return s2 end,readLine=function()if t1>=#s1 then return nil end local p2=s1:find("\n",t1+1,true)if p2 then local q2=s1:sub(t1+1,p2-1)t1=p2 return q2 end local r2=s1:sub(t1+1)t1=#s1 return r2 end,write=function()end,writeLine=function()end,close=function()end,flush=function()return true end,seek=function(s2,t2,u2)local q2,r2 if type(s2)=="table"then q2,r2=t2,u2 else q2,r2=s2,t2 end r2=r2 or 0 local p2 if q2==nil or q2=="cur"then p2=t1+r2 elseif q2=="set"then p2=r2 elseif q2=="end"then p2=#s1+r2 else return nil,"bad whence"end if p2<0 then return nil,"negative seek"end t1=p2 return p2 end,}end,makeDir=function(u1)local t1=u1:match("^(.*)/[^/]*$")or"/"local v1=u1:match("([^/]*)$")or u1 local s1=a.lookup(q1,t1)local y1=q()if s1 and not(f(s1,y1.uid,y1.gid,2)and f(s1,y1.uid,y1.gid,1))then error("permission denied",2)end local x1,w1=a.create(q1,t1,v1,0x41ED)if not x1 then error(tostring(w1),2)end return true end,delete=function(u1)local t1=u1:match("^(.*)/[^/]*$")or"/"local v1=u1:match("([^/]*)$")or u1 local s1=a.lookup(q1,t1)local x1=q()if s1 and not(f(s1,x1.uid,x1.gid,2)and f(s1,x1.uid,x1.gid,1))then error("permission denied",2)end local y1,w1=a.delete(q1,t1,v1)if not y1 then error(tostring(w1),2)end return true end,chmod=function(t1,s1)return a.chmod(q1,t1,s1)end,chown=function(t1,u1,s1)return a.chown(q1,t1,u1,s1)end,canExecute=function(t1)local s1=a.lookup(q1,t1)if not s1 then return false end if s1.type~=t and s1.type~=m then return false end local u1=q()if u1.uid==0 then return g1(s1.perms)end return f(s1,u1.uid,u1.gid,1)end,}end function a.mkfs(n2,l2)l2=l2 or{}local q1=1024 local t1=tonumber(l2.blocks)if not t1 then return nil,"mkfs: 必须给 blocks"end t1=math.floor(t1)if t1<64 then return nil,"mkfs: 块数至少 64(64KB)"end if t1>8192 then return nil,"mkfs: 只支持单块组(最多 8192 块 = 8MB)"end local y1,s1,v1=128,256,8192 local w1=1 local i2=11 local z1,a2,c2=3,4,5 local b2=math.ceil(s1*y1/q1)local u1=c2+b2 if t1<u1+2 then return nil,string.format("mkfs: 块数至少 %d(元数据 %d 块 + 根目录 + lost+found)",u1+2,u1)end local q2=n2.getSize and n2.getSize()or nil if q2 and q2>0 and q2<t1*q1 then return nil,string.format("mkfs: 设备只有 %d 字节, 放不下 %d 块(%d 字节)",q2,t1,t1*q1)end local k2=math.floor(l2.time or(os.epoch and(os.epoch("utc")/1000))or os.time())local w2=64*1024 local r2=string.rep("\0",math.min(w2,t1*q1))local m2=0 while m2<t1*q1 do local k3=math.min(#r2,t1*q1-m2)local l3,b3=n2.write(m2,k3==#r2 and r2 or r2:sub(1,k3))if not l3 then return nil,string.format("mkfs: 清零失败于偏移 %d: %s",m2,tostring(b3))end m2=m2+k3 end local r1=string.rep("\0",1024)r1=d(r1,0,s1)r1=d(r1,4,t1)r1=d(r1,8,0)r1=d(r1,12,t1-u1-1)r1=d(r1,16,s1-10)r1=d(r1,20,w1)r1=d(r1,24,0)r1=d(r1,28,0)r1=d(r1,32,v1)r1=d(r1,36,v1)r1=d(r1,40,s1)r1=d(r1,44,k2)r1=d(r1,48,k2)r1=g(r1,52,0)r1=g(r1,54,0xFFFF)r1=g(r1,56,0xEF53)r1=g(r1,58,1)r1=g(r1,60,1)r1=g(r1,62,0)r1=d(r1,64,k2)r1=d(r1,68,0)r1=d(r1,72,0)r1=d(r1,76,1)r1=g(r1,80,0)r1=g(r1,82,0)r1=d(r1,84,i2)r1=g(r1,88,y1)r1=g(r1,90,0)r1=d(r1,92,0)r1=d(r1,96,0x2)r1=d(r1,100,0)local s2=k2%2147483647 local v2={}for m3=1,16 do s2=(s2*1103515245+12345)%2147483648 v2[m3]=string.char(math.floor(s2/8388608)%256)end r1=r1:sub(1,104)..table.concat(v2)..r1:sub(121)local t2=tostring(l2.label or"delin"):sub(1,15)r1=r1:sub(1,120)..t2..string.rep("\0",16-#t2)..r1:sub(137)if not n2.write(1024,r1)then return nil,"mkfs: 写超级块失败"end local e2=u1 local o2=t1-e2-1 local g3=y(z1)..y(a2)..y(c2)..v(o2)..v(s1-10)..v(1)..v(0)..string.rep("\0",12)if not n2.write(2*q1,g3)then return nil,"mkfs: 写块组描述符失败"end local function d2(q3,p3)local o3=math.floor(p3/8)+1 local r3=q3:byte(o3)or 0 return q3:sub(1,o3-1)..string.char(r3+2^(p3%8))..q3:sub(o3+1)end local x1=q1*8 local h2=string.rep("\0",q1)for c3=0,e2-1 do h2=d2(h2,c3)end for f3=t1-1,x1-1 do h2=d2(h2,f3)end if not n2.write(z1*q1,h2)then return nil,"mkfs: 写块位图失败"end local j2=string.rep("\0",q1)for d3=0,9 do j2=d2(j2,d3)end for e3=s1,x1-1 do j2=d2(j2,e3)end if not n2.write(a2*q1,j2)then return nil,"mkfs: 写 inode 位图失败"end local y2={bd=n2,blockSize=q1,inodes=s1,blocks=t1,rBlocks=0,firstDataBlock=w1,inodesPerGroup=s1,blocksPerGroup=v1,inodeSize=y1,firstIno=i2,gdtOffset=2*q1,numGroups=1,}local f2=u1 local h3=y(2)..v(12)..string.char(1,w).."."..string.rep("\0",3)local i3=y(2)..v(q1-12)..string.char(2,w)..".."..string.rep("\0",2)if not b(y2,f2,h3..i3)then return nil,"mkfs: 写根目录失败"end local g2={ino=2,mode=e+493,uid=0,gid=0,links=2,size=q1,blocks=math.floor(q1/512),atime=k2,ctime=k2,mtime=k2,ptrs={f2},}for n3=2,15 do g2.ptrs[n3]=0 end if not a.writeInode(y2,g2)then return nil,"mkfs: 写根 inode 失败"end local j3,z2=a.create(y2,"/","lost+found",e+448)if not j3 then return nil,"mkfs: 建 lost+found 失败: "..tostring(z2)end local u2,a3=a.mount(n2)if not u2 then return nil,"mkfs: 自检挂载失败: "..tostring(a3)end local p2=a.lookup(u2,"/")if not p2 or p2.type~=e then return nil,"mkfs: 自检读不到根目录"end local x2=a.lookup(u2,"/lost+found")if not x2 or x2.type~=e then return nil,"mkfs: 自检读不到 /lost+found"end if p2.links~=3 then return nil,"mkfs: 根目录 links 应为 3, 实得 "..tostring(p2.links)end return u2 end return a end __chunks["kernel.fb"]=function()local _ENV=setmetatable({require=__require},{__index=_G})local i={}local b=0 local c={}local a=0x000000 local function f(k,n,m,l)return k*16777216+n*65536+m*256+l end local function e(k)local l=math.floor(k/16777216)%256 local o=math.floor(k/65536)%256 local n=math.floor(k/256)%256 local m=k%256 return string.char(l,o,n,m)end local function d(k,l,m)if not k.hasDirty then k.dirtyX0,k.dirtyY0,k.dirtyX1,k.dirtyY1=l,m,l,m k.hasDirty=true else if l<k.dirtyX0 then k.dirtyX0=l end if m<k.dirtyY0 then k.dirtyY0=m end if l>k.dirtyX1 then k.dirtyX1=l end if m>k.dirtyY1 then k.dirtyY1=m end end end local function j(k)local o,n=k.getSize()o=math.floor(o)n=math.floor(n)local q=o*n local m={}for p=1,q do m[p]=a end local l={dev=k,w=o,h=n,px=m,pos=0,hasDirty=false,dirtyX0,dirtyY0,dirtyX1,dirtyY1=0,0,0,0,closed=false,}return l end local function h(k)if k.closed or not k.hasDirty then return true end local l,n=k.dirtyX0,k.dirtyY0 local m,o=k.dirtyX1,k.dirtyY1 k.hasDirty=false for r=n,o do for q=l,m do local p=k.px[r*k.w+q+1]if p~=a then k.dev.setPixel(q,r,p)end end end k.dev.flush()return true end local function g(k,l)return{write=function(self,m)if k.closed then return nil,"device closed"end if type(m)~="string"then return nil,"expected string"end local o=1 local n=math.floor(#m/4)for v=0,n-1 do local r,u,t,s=m:byte(o,o+3)local q=k.pos%k.w local p=math.floor(k.pos/k.w)if p<k.h then k.px[p*k.w+q+1]=f(r,u,t,s)d(k,q,p)end k.pos=(k.pos+1)%(k.w*k.h)o=o+4 end return#m end,read=function(self,o)if k.closed then return nil,"device closed"end o=o or(k.w*k.h*4)local m=math.floor(o/4)local n={}for q=0,m-1 do local p=(k.pos+q)%(k.w*k.h)local r=p%k.w local s=math.floor(p/k.w)n[#n+1]=e(k.px[s*k.w+r+1])end k.pos=(k.pos+m)%(k.w*k.h)return table.concat(n)end,seek=function(self,m)local n=m or 0 k.pos=math.floor(n/4)%(k.w*k.h)return k.pos end,clear=function(self,m)if k.closed then return nil,"device closed"end for n=0,k.w-1 do for o=0,k.h-1 do k.px[o*k.w+n+1]=m end end k.hasDirty=true k.dirtyX0,k.dirtyY0,k.dirtyX1,k.dirtyY1=0,0,k.w-1,k.h-1 return true end,setPixel=function(self,n,o,m)if k.closed then return nil,"device closed"end n,o=math.floor(n or 0),math.floor(o or 0)if n<0 or o<0 or n>=k.w or o>=k.h then return nil,"out of range"end k.px[o*k.w+n+1]=m d(k,n,o)return true end,getSize=function()return k.w,k.h end,getBpp=function()return 32 end,getPixel=function(self,m,n)if m<0 or n<0 or m>=k.w or n>=k.h then return nil end return k.px[n*k.w+m+1]end,flush=function(self)if k.closed then return nil,"device closed"end return h(k)end,close=function(self)k.closed=true return true end,}end function i.registerDevice(n)local m="fb"..b b=b+1 local l=j(n)c[m]=l local k={writable=true,open=function(o)return g(l,o)end,getCtx=function()return l end,}return m,k end function i.get(k)return c[k]end function i.list()local k={}for l in pairs(c)do k[#k+1]=l end return k end function i.resize(n)local k=c[n]if not k then return end local p,q=k.dev.getSize()p=math.floor(p)q=math.floor(q)local m,o=k.w,k.h local l={}for s=0,q-1 do for r=0,p-1 do if r<m and s<o then l[s*p+r+1]=k.px[s*m+r+1]else l[s*p+r+1]=a end end end k.px=l k.w,k.h=p,q k.pos=0 k.hasDirty=true k.dirtyX0,k.dirtyY0,k.dirtyX1,k.dirtyY1=0,0,p-1,q-1 return true end return i end __chunks["kernel.fifo"]=function()local _ENV=setmetatable({require=__require},{__index=_G})local c=require("kernel.pipe")local b={}local a=setmetatable({},{__mode="k"})local function d(e,f)local g=a[e]if not g then g={};a[e]=g end local h=g[f]if not h then h=c.newBuf();g[f]=h end return h end function b.open(g,j,f)f=f or"r"local e=d(g,j)e.pendingReaders=e.pendingReaders or 0 e.pendingWriters=e.pendingWriters or 0 e.readerEpoch=e.readerEpoch or 0 e.writerEpoch=e.writerEpoch or 0 if f:find("w")or f:find("a")then local i=e.readerEpoch e.pendingWriters=e.pendingWriters+1 while e.readers==0 and e.pendingReaders==0 and e.readerEpoch==i do os.sleep(0.05)end e.pendingWriters=e.pendingWriters-1 return c.attachWrite(e)end if f:find("r")then local h=e.writerEpoch e.pendingReaders=e.pendingReaders+1 while e.writers==0 and e.pendingWriters==0 and e.writerEpoch==h do os.sleep(0.05)end e.pendingReaders=e.pendingReaders-1 return c.attachRead(e)end error("fifo: unsupported open mode: "..tostring(f),2)end function b.counts(e,g)local h=a[e]local f=h and h[g]if not f then return 0,0 end return f.readers,f.writers end function b.forget(e,f)local g=a[e]if g then g[f]=nil end end return b end __chunks["kernel.fstab"]=function()local _ENV=setmetatable({require=__require},{__index=_G})local a={}local b={defaults=true,noauto=true,nofail=true,auto=true,ro="ignored",rw="ignored",user="ignored",users="ignored",}function a.parse(i,e)e=e or"/etc/fstab"local d={}local c=0 for q in(i.."\n"):gmatch("([^\n]*)\n")do c=c+1 local l=q:gsub("#.*$",""):gsub("^%s+",""):gsub("%s+$","")if l~=""then local n={}for r in l:gmatch("%S+")do n[#n+1]=r end if#n<3 then return nil,string.format("%s:%d: need at least <device> <mountpoint> <fstype>",e,c)end local g=n[4]or"defaults"local m={}for f in(g..","):gmatch("([^,]*),")do f=f:gsub("^%s+",""):gsub("%s+$","")if f~=""then local o=b[f]if not o then return nil,string.format("%s:%d: unknown mount option '%s'",e,c,f)end m[f]=true end end local function p(u,s)if u==nil then return 0 end local t=tonumber(u)if not t or t<0 or t~=math.floor(t)then return nil,string.format("%s:%d: bad %s field '%s'",e,c,s,u)end return t end local j,k=p(n[5],"dump")if not j then return nil,k end local h h,k=p(n[6],"pass")if not h then return nil,k end d[#d+1]={device=n[1],mountpoint=n[2],fstype=n[3],options=g,opts=m,dump=j,pass=h,line=c,}end end return d end function a.read(e,c)c=c or"/etc/fstab"if not e.exists(c)then return{}end local l,i=e.open(c,"r")if not l then return nil,c..": "..tostring(i)end local f=l.readAll()l.close()local d,j=a.parse(f,c)if not d then return nil,j end for m,k in ipairs(d)do local g,h=a.escapeMount(k.mountpoint)if not g then return nil,string.format("%s:%d: %s",c,k.line,h)end k.unit=g..".mount"end return d end function a.escapeMount(c)if c=="/"then return"-"end local d=c:gsub("^/+",""):gsub("/+$","")if d==""then return nil,"empty mount point"end d=d:gsub("/","-")if d:find("[^A-Za-z0-9_.%-]")then return nil,"mount point has characters not representable in a unit name: "..c end return d end return a end __chunks["kernel.klog"]=function()local _ENV=setmetatable({require=__require},{__index=_G})local q=require("kernel.vfs_api")local a={}local e={kern=0,user=1,mail=2,daemon=3,auth=4,syslog=5,lpr=6,news=7,uucp=8,cron=9,authpriv=10,ftp=11,local0=16,local1=17,local2=18,local3=19,local4=20,local5=21,local6=22,local7=23,}local f={emerg=0,alert=1,crit=2,err=3,warning=4,notice=5,info=6,debug=7,}local i,j={},{}for w,y in pairs(e)do i[y]=w end for x,z in pairs(f)do j[z]=x end a.FACILITIES=e a.SEVERITIES=f function a.split(a1)return math.floor(a1/8),a1%8 end function a.makePri(a1,b1)return a1*8+b1 end function a.facilityName(a1)return i[a1]or("fac"..a1)end function a.severityName(a1)return j[a1]or("sev"..a1)end local r=16384 local o=os.epoch("utc")local n={}local c=1 local g=1 local h=0 local k=0 function a.write(d1,a1)a1=tostring(a1 or"")local c1=(os.epoch("utc")-o)*1000 for b1 in(a1.."\n"):gmatch("([^\n]*)\n")do n[g]={seq=g,usec=c1,pri=d1,text=b1}h=h+#b1+1 g=g+1 end while h>r and c<g do local e1=n[c]h=h-(#e1.text+1)n[c]=nil c=c+1 k=k+1 end end function a.kern(a1)a.write(a.makePri(e.kern,f.info),a1)end function a.user(a1)a.write(a.makePri(e.user,f.info),a1)end function a.stats()return{first=c,next=g,bytes=h,drops=k,boot=o}end local function m(a1)return string.format("%d,%d,%d,-;%s",a1.pri,a1.seq,a1.usec,a1.text)end local function s()local a1=c local b1=false local c1={readAvailable=function()if b1 then return""end local d1={}while a1<g do local e1=n[a1]a1=a1+1 if e1 then d1[#d1+1]=m(e1)end end return table.concat(d1,"\n")..(#d1>0 and"\n"or"")end,readLine=function()while not b1 do if a1<g then local d1=n[a1]a1=a1+1 if d1 then return m(d1)end else os.sleep(0.05)end end return nil end,cursor=function()return a1 end,seek=function(e1,f1)local d1=(type(e1)=="table")and f1 or e1 d1=tonumber(d1)if not d1 then return nil,"seek: bad sequence number"end a1=math.max(math.floor(d1),c)return true end,close=function()b1=true;return true end,flush=function()return true end,getDeviceName=function()return"kmsg"end,}return c1 end local t=8192 local b={}local d=0 local l=0 local function p(a1)b[#b+1]=a1 d=d+#a1+1 while d>t and#b>1 do local b1=table.remove(b,1)d=d-(#b1+1)l=l+1 end end local function v()local a1=""local b1=false return{write=function(f1,e1)if b1 then return nil,"log closed"end e1=tostring(e1 or"")a1=a1..e1 while true do local d1=a1:find("\n",1,true)if not d1 then break end local c1=a1:sub(1,d1-1)a1=a1:sub(d1+1)if c1~=""then p(c1)end end return#e1 end,writeLine=function(self,c1)return self:write(tostring(c1 or"").."\n")end,flush=function()return true end,close=function()if not b1 and a1~=""then p(a1);a1=""end b1=true return true end,getDeviceName=function()return"log"end,}end local function u()local a1=false return{readAvailable=function()if a1 or#b==0 then return""end local b1=table.concat(b,"\n").."\n"b,d={},0 return b1 end,readLine=function()while not a1 do if#b>0 then local b1=table.remove(b,1)d=d-(#b1+1)return b1 end os.sleep(0.05)end return nil end,close=function()a1=true;return true end,flush=function()return true end,getDeviceName=function()return"log"end,}end function a.logDrops()return l end function a.register()q.registerDevice("kmsg",{writable=false,open=function(a1)if a1 and a1:find("[wa+]")then return nil,"/dev/kmsg: read-only"end return s()end,})q.registerDevice("log",{writable=true,open=function(a1)if a1 and a1:find("r")then return u()end return v()end,})end function a.registerSyscalls(a1)a1["syslog.facility"]=function(b1)return e[(b1 or""):lower()]end a1["syslog.severity"]=function(b1)return f[(b1 or""):lower()]end a1["syslog.facilityName"]=function(b1)return a.facilityName(b1)end a1["syslog.severityName"]=function(b1)return a.severityName(b1)end a1["syslog.facilities"]=function()local b1={}for c1 in pairs(e)do b1[#b1+1]=c1 end table.sort(b1)return b1 end a1["syslog.severities"]=function()local b1={}for c1 in pairs(f)do b1[#b1+1]=c1 end table.sort(b1)return b1 end a1["klog.stats"]=function()return a.stats()end a1["klog.logDrops"]=function()return a.logDrops()end end return a end __chunks["kernel.manifest"]=function()local _ENV=setmetatable({require=__require},{__index=_G})local a={}function a.parse(f)local d,b={},nil for c in f:gmatch("[^\r\n]+")do c=c:match("^%s*(.-)%s*$")if c~=""and c:sub(1,1)~="#"then local e,h,g=c:match("^(%S+)%s+(%S+)%s*(%S*)%s*$")if e then if e=="boot"then b=h else d[#d+1]={role=e,path=h,fstype=g or""}end end end end return{partitions=d,boot=b}end function a.findRoot(c)for d,b in ipairs(c.partitions)do if b.role=="root"then return b end end return nil end return a end __chunks["kernel.modules"]=function()local _ENV=setmetatable({require=__require},{__index=_G})local i=require("kernel.vfs_api")local p=require("kernel.vfs")local g=require("kernel.display")local m=require("kernel.devdisk")local l=require("kernel.sysfs")local n=require("kernel.version")local a={}a.version=n a.log=print a.fs=fs local e={}local c={}local function o(q)return(q:match("^%s*(.-)%s*$"))end local function j(v)local q={name=nil,version=nil,deps={},author=nil,description=nil}for u in v:gmatch("[^\r\n]+")do local s=u:match("^%s*(.-)%s*$")if s==""then elseif s:sub(1,1)~="-"then break else local r,t=u:match("^%s*%-%-@([%w_]+)%s+(.-)%s*$")if r then if r=="name"then q.name=t elseif r=="version"then q.version=t elseif r=="author"then q.author=t elseif r=="description"then q.description=t elseif r=="deps"then for w in t:gmatch("[^,%s]+")do q.deps[#q.deps+1]=w end end end end end if not q.name then q.name="unnamed"end return q end local function h(q)local r=a.fs.open(q,"r")if not r then return nil end local s=r.readAll()r.close()return s end local function k(q)return{name=q,version=a.version,log=a.log,registerSyscall=function(s,r)c[s]=r end,registerDevice=function(s,r)i.registerDevice(s,r)end,unregisterDevice=function(r)i.unregisterDevice(r)end,registerFS=function(t,r,s)p.mount(t,r,s)end,registerFstype=function(r,s)m.registerFstype(r,s)end,registerDisplay=function(r)return g.register(r)end,unregisterDisplay=function(r)g.unregister(r)end,displayList=function()return g.list()end,registerSysfsClass=function(r,s)l.registerClass(r,s)end,unregisterSysfsClass=function(r)l.unregisterClass(r)end,}end local b=nil function a.init(q)b=q end local function d(q,x)if e[q]and e[q].state=="active"then return true end if not b then return nil,"module manager not initialized"end local y=h(b.."/"..q..".ko")if not y then return nil,"module file not found: "..q end local r=j(y)for h1,a1 in ipairs(r.deps)do local f1,d1=d(a1)if not f1 then return nil,"dep '"..a1.."' failed: "..tostring(d1)end end local c1=setmetatable({require=require},{__index=_G})local t,v=load(y,q,"t",c1)if not t then return nil,"load failed: "..tostring(v)end local z,s=pcall(t)if not z then return nil,"module body error: "..tostring(s)end if type(s)~="table"then return nil,"module must return a table: "..q end local u={name=q,meta=r,mod=s,deps=r.deps,ref=0,state="loading"}if s.init then local e1,b1=pcall(s.init,k(q),x)if not e1 then u.state="error";e[q]=u return nil,"init error: "..tostring(b1)end end u.state="active";e[q]=u for g1,w in ipairs(r.deps)do if e[w]then e[w].ref=e[w].ref+1 end end a.log(string.format("[module] loaded '%s' v%s (deps:%s)",q,r.version or"?",table.concat(r.deps,",")))return true end function a.load(q)return d(q)end local f={}function a.loadAliases()if not b then return nil,"module manager not initialized"end local t=h(b.."/modules.alias")if not t then return nil,"no modules.alias at "..b end f={}for q in t:gmatch("[^\r\n]+")do q=q:gsub("%s*#.*$",""):gsub("^%s*",""):gsub("%s*$","")if q~=""then local r,s=q:match("^(%S+)%s+(%S+)$")if r and s then f[r]=s end end end return true end function a.use(r,s)local q=f[r]if not q then return nil,"no module for alias '"..tostring(r).."' (see modules.alias)"end return d(q,s)end function a.loadAll()if not b then return nil,"module manager not initialized"end local q=h(b.."/manifest")if not q then return nil,"no manifest at "..b.."/manifest"end local s={}for r in q:gmatch("[^\r\n]+")do r=o(r)if r~=""then s[#s+1]=r end end for w,t in ipairs(s)do local v,u=d(t)if not v then return nil,u end end return true end function a.unload(q)local r=e[q]if not r then return nil,"not loaded: "..q end if r.ref>0 then return nil,"module in use (refcount="..r.ref.."): "..q end if r.mod and r.mod.exit then local u,t=pcall(r.mod.exit)if not u then a.log("module exit error "..q..": "..tostring(t))end end for v,s in ipairs(r.deps)do if e[s]then e[s].ref=math.max(0,e[s].ref-1)end end r.state="unloaded";e[q]=nil a.log("[module] unloaded '"..q.."'")return true end function a.reload(q)local s,r=a.unload(q)if not s then return nil,r end return d(q)end function a.syscalls()return c end function a.applyToEnv(q)q.syscalls=c end c["modules.load"]=function(q)return a.load(q)end c["modules.unload"]=function(q)return a.unload(q)end c["modules.reload"]=function(q)return a.reload(q)end c["modules.list"]=function()local q={}for r,s in pairs(e)do q[#q+1]=r..":"..s.state end return q end return a end __chunks["kernel.pipe"]=function()local _ENV=setmetatable({require=__require},{__index=_G})local d={}local g=16384 local function e()return{data="",writers=0,readers=0,pendingWriters=0,pendingReaders=0,writerEpoch=0,readerEpoch=0}end local function c(h)return h.writers+(h.pendingWriters or 0)==0 end local function f(h)return h.readers+(h.pendingReaders or 0)==0 end local function a(h)h.writers=h.writers+1 h.writerEpoch=(h.writerEpoch or 0)+1 local i=false local j={pipe=true,write=function(p,n)if i then return nil,"pipe closed"end n=tostring(n or"")local m,o=1,#n while m<=o do if f(h)then return nil,"broken pipe"end local l=g-#h.data if l<=0 then os.sleep(0.05)else local k=n:sub(m,m+l-1)h.data=h.data..k m=m+#k end end return o end,flush=function()return true end,close=function()if not i then i=true;h.writers=h.writers-1 end return true end,}return j end local function b(h)h.readers=h.readers+1 h.readerEpoch=(h.readerEpoch or 0)+1 local i=false local j j={pipe=true,readLine=function()if i then return nil end while true do local l=h.data:find("\n",1,true)if l then local k=h.data:sub(1,l-1)h.data=h.data:sub(l+1)return k end if c(h)then if#h.data>0 then local m=h.data;h.data="";return m end return nil end os.sleep(0.05)end end,read=function(n,k)if i then return nil end if k==nil or k=="*l"then return j.readLine()end if k=="a"then return j.readAll()end local m=tonumber(k)or 0 if m<=0 then return""end while#h.data==0 do if c(h)then return nil end os.sleep(0.05)end local l=h.data:sub(1,m)h.data=h.data:sub(m+1)return l end,readAll=function()if i then return nil end local k={}while true do if#h.data>0 then k[#k+1]=h.data;h.data=""end if c(h)then break end os.sleep(0.05)end local l=table.concat(k)return l~=""and l or nil end,close=function()if not i then i=true;h.readers=h.readers-1 end return true end,}return j end function d.create()local h=e()return b(h),a(h)end function d.newBuf()return e()end function d.attachRead(h)return b(h)end function d.attachWrite(h)return a(h)end return d end __chunks["kernel.procenv"]=function()local _ENV=setmetatable({require=__require},{__index=_G})local a={}local d={"colors","colours","keys","vector","textutils","parallel","term","write","read","printError","sleep","window","paintutils","redstone","rednet","gps","http","turtle","_HOST","_CC_DEFAULT_SETTINGS",}local b={"assert","collectgarbage","error","getmetatable","ipairs","load","loadstring","next","pairs","pcall","rawequal","rawget","rawlen","rawset","select","setfenv","getfenv","setmetatable","tonumber","tostring","type","unpack","xpcall","_VERSION",}local c={"string","table","math","coroutine"}local e={loadAPI=true,unloadAPI=true,run=true,pullEvent=true,pullEventRaw=true,queueEvent=true,shutdown=true,reboot=true,exit=true,remove=true,rename=true,tmpname=true,getenv=true,}local function f(i)local g={}for j,k in pairs(i)do g[j]=k end local h=getmetatable(i)if type(h)=="table"then setmetatable(g,h)end return g end function a.apply(g)for q,i in ipairs(b)do local n=_G[i]if n~=nil then g[i]=n end end for s,j in ipairs(c)do local o=_G[j]if o~=nil then g[j]=f(o)end end local k={}for m,p in pairs(_G.os)do if not e[m]then k[m]=p end end g.os=k for r,h in ipairs(d)do local l=_G[h]if type(l)=="table"then g[h]=f(l)elseif l~=nil then g[h]=l end end g.debug={traceback=_G.debug.traceback}end return a end __chunks["kernel.process"]=function()local _ENV=setmetatable({require=__require},{__index=_G})local c=require("kernel.signal")local k=require("kernel.scheduler")local x=require("kernel.tty")local q=require("kernel.vfs_api")local p=require("kernel.modules")local v=require("kernel.procenv")local a={}a.next_pid=0 a.log=nil local b={}local d={}local t={}local f={}local e={}local function w(...)if a.log then a.log(...)else print(...)end end local function u()a.next_pid=a.next_pid+1 return a.next_pid end local function s(g1,e1,i1,h1,a1,b1)a1=a1 or{}b1=b1 or{}local d1={}for j1=1,#a1 do d1[j1]=a1[j1]end local f1=b[e1]and b[e1].cwd or"/"local z={}local y=b[e1]if y and y.envvars then for m1,n1 in pairs(y.envvars)do z[m1]=n1 end end if b1.env then for k1,l1 in pairs(b1.env)do if l1==nil then z[k1]=nil else z[k1]=tostring(l1)end end end local c1={pid=g1,ppid=e1,uid=i1 or 0,gid=h1 or 0,cwd=b1.cwd or f1 or"/",argv=a1,args=d1,argc=#d1,arg0=a1[0]or d1[1]or"",env=z,getenv=function(o1)return z[o1]end,print=w,spawn=function(t1,s1,r1,q1,o1,p1)return a.spawn(t1,s1,g1,r1,q1,o1,p1)end,}v.apply(c1)q.installForEnv(c1)p.applyToEnv(c1)c1._G=c1 return c1 end local function o()return{pending={},handlers={},ignored={},stopped=false,stopSig=nil,termSig=nil,}end local function r(y,z)if not d[y]then d[y]={}end d[y][z]=true end local function j(a1)local z=d[a1]if not z then return end if not d[1]then d[1]={}end for y in pairs(z)do local b1=b[y]if b1 then b1.ppid=1 end d[1][y]=true end d[a1]=nil end function a.spawn(q1,i1,e1,n1,m1,h1,c1)if c1 and c1.ppid then e1=c1.ppid end e1=e1 or 0 if type(q1)~="string"then return nil,nil,"spawn expects a source string, got "..type(q1)end local a1=b[e1]n1=n1 or(a1 and a1.uid)or 0 m1=m1 or(a1 and a1.gid)or 0 h1=h1 or{}local b1=u()local p1,j1 if a1 then p1=a1.sid or 0 j1=a1.pgrp or a1.pid else p1=0 j1=b1 end local g1=s(b1,e1,n1,m1,h1,c1)local z=b[e1]local k1=c1 and c1.stdio if k1 then g1.__stdio.input=k1.input g1.__stdio.output=k1.output else local f1=(z and z.stdio)or q.getStdio()if f1 then g1.__stdio.input=f1.input g1.__stdio.output=f1.output end end local l1,o1=load(q1,i1 or("proc#"..b1),"t",g1)if not l1 then return nil,nil,"load failed: "..tostring(o1)end local s1=coroutine.create(l1)t[s1]=b1 local y={pid=b1,ppid=e1,name=i1 or("proc#"..b1),co=s1,status="running",exitCode=nil,termSig=nil,uid=n1,gid=m1,cwd=g1.cwd,argv=h1,envvars=g1.env,stdio=g1.__stdio,pgrp=j1,sid=p1,umask=(z and z.umask)or tonumber("022",8),sig=o(),}do local r1=c1 and c1.sigIgnore local d1=z and z.sig if d1 and d1.ignored then for t1 in pairs(d1.ignored)do y.sig.ignored[t1]=true end end if r1 then for u1 in pairs(r1)do y.sig.ignored[u1]=true end end end y.onExit=function(d2,v1,a2,x1)y.status=v1 y.exitCode=(v1=="dead")and((type(x1)=="number")and x1 or 0)or nil if y.stdio then local z1,y1=y.stdio.output,y.stdio.input if z1 and z1.pipe and z1.close then pcall(z1.close)end if y1 and y1.pipe and y1.close then pcall(y1.close)end end if v1=="error"then y.error=a2 if a.log then pcall(a.log,"[proc "..b1.." "..tostring(i1).."] ERROR: "..tostring(a2))end end if y.sid==b1 then local w1=f[y.sid]if w1 then if w1.ctty and e[w1.ctty]==w1.sid then e[w1.ctty]=nil end f[y.sid]=nil end end j(b1)if a.onExit then local c2,b2=pcall(a.onExit,b1,v1,y.exitCode,y.termSig)if not c2 and a.log then a.log("[proc exit hook] "..tostring(b2))end end end b[b1]=y r(e1,b1)k.addProcess({pid=b1,co=s1,name=y.name,started=false,filter=nil,dead=false,status="running",onExit=y.onExit,sig=y.sig,canonical=y,})return b1,y,nil end function a.info(y)return b[y]end function a.list()local y={}for a1,z in pairs(b)do if z.status=="running"or z.status=="stopped"then y[#y+1]=z end end table.sort(y,function(b1,c1)return b1.pid<c1.pid end)return y end function a.ttyFor(z)local a1=b[z]if not a1 then return nil end local y=f[a1.sid]if not y then return nil end return y.ctty end function a.fgPgrpFor(z)local a1=b[z]if not a1 then return nil end local y=f[a1.sid]if not y then return nil end return y.fgPgrp end function a.setExitHook(y)a.onExit=y end local g={}function a.current()local z=coroutine.running()local y=z and t[z]local a1=z and g[z]if a1 then return{pid=y or 0,uid=a1.uid,gid=a1.gid,umask=tonumber("022",8)}end if not y then return{pid=0,uid=0,gid=0,umask=tonumber("022",8)}end local b1=b[y]if not b1 then return{pid=0,uid=0,gid=0,umask=tonumber("022",8)}end return{pid=y,uid=b1.uid,gid=b1.gid,umask=b1.umask or tonumber("022",8)}end function a.asRoot(a1)local y=coroutine.running()local z=y and g[y]if y then g[y]={uid=0,gid=0}end local b1,c1,d1=pcall(a1)if y then g[y]=z end if not b1 then error(c1,0)end return c1,d1 end function a.currentGroup()local y=a.current()local z=b[y.pid]if not z then return nil,nil end return z.pgrp,z.sid end function a.setStdio(z,y)local a1=a.current()local b1=b[a1.pid]if not b1 or not b1.stdio then return false end b1.stdio.input=z b1.stdio.output=y return true end function a.kill(z,a1)local b1=b[z]if not b1 then return nil,"no such process: "..tostring(z)end local y=a.current()if y.uid~=0 and y.uid~=b1.uid then return nil,"permission denied"end b1.sig.pending[a1]=true return true end function a.signalGroup(z,b1)local y=b[z]if not y then return nil,"no such process group: "..tostring(z)end local a1=a.current()if a1.uid~=0 and a1.uid~=y.uid then return nil,"permission denied"end local c1=0 for e1,d1 in pairs(b)do if d1.pgrp==z then d1.sig.pending[b1]=true c1=c1+1 end end if c1==0 then return nil,"no such process group"end return c1 end function a.setHandler(y,z)if not c.catchable(y)then return nil,"uncatchable signal: "..c.name(y)end local b1=a.current()local a1=b[b1.pid]if not a1 then return nil,"no current process"end if z=="ignore"then a1.sig.handlers[y]=nil a1.sig.ignored[y]=true return true end if z=="default"then a1.sig.handlers[y]=nil a1.sig.ignored[y]=nil return true end a1.sig.ignored[y]=nil a1.sig.handlers[y]=z return true end function a.setsid()local a1=a.current()local z=b[a1.pid]if not z then return nil,"no current process"end if z.pgrp==z.pid then return nil,"setsid: already a process group leader"end local y=z.pid z.sid=y z.pgrp=y f[y]={sid=y,leader=z.pid,ctty=nil,fgPgrp=y}return y end function a.setpgid(a1,y)local b1=b[a1]if not b1 then return nil,"no such process: "..tostring(a1)end if b1.pid==b1.sid then return nil,"setpgid: session leader"end local c1=a.current()local z=b[c1.pid]if z.sid~=b1.sid then return nil,"setpgid: cross-session"end if y==0 or y==nil then y=b1.pid end b1.pgrp=y return true end function a.tcsetpgrp(y,a1)local e1=a.current()local b1=b[e1.pid]local z=e[y]if not z then if not b1 then return nil,"tcsetpgrp: no current process"end z=b1.sid if not z or z==0 then return nil,"tcsetpgrp: no session"end f[z].ctty=y e[y]=z end local d1=f[z]if not d1 then return nil,"tcsetpgrp: no session"end if not a1 or a1==0 then a1=e1.pid end local c1=false for g1,f1 in pairs(b)do if f1.pgrp==a1 and f1.sid==z then c1=true;break end end if not c1 then return nil,"tcsetpgrp: not a process group in session"end d1.fgPgrp=a1 return true end function a.tcgetpgrp(y)local a1=e[y]if not a1 then return nil end local z=f[a1]if not z then return nil end return z.fgPgrp end function a.sessionForTty(y)return e[y]end function a.checkTtyRead(z)local b1=a.current()local c1=b[b1.pid]if not c1 then return false end local a1=e[z]if not a1 then return false end if c1.sid~=a1 then return false end local y=f[a1]if not y or not y.fgPgrp then return false end if c1.pgrp==y.fgPgrp then return false end c1.sig.pending[c.SIGTTIN]=true return true end x.readGuard=a.checkTtyRead function a.applySignals(d1)local z=d1.sig if not z then return"run"end local y=z.pending if z.stopped and next(y)==nil then return"stop"end if next(y)==nil then return"run"end local c1={}for i1 in pairs(y)do c1[#c1+1]=i1 end table.sort(c1)local b1=false for j1,a1 in ipairs(c1)do if b1 then break end if a1==c.SIGCONT then if z.stopped then z.stopped=false z.stopSig=nil if d1.canonical then d1.canonical.status="running"end end y[a1]=nil elseif a1==c.SIGKILL then z.termSig=a1 if d1.canonical then d1.canonical.termSig=a1 end b1=true y[a1]=nil elseif a1==c.SIGSTOP then if not z.stopped then z.stopped=true z.stopSig=a1 if d1.canonical then d1.canonical.status="stopped"end end y[a1]=nil else local h1=z.handlers[a1]if z.ignored and z.ignored[a1]then y[a1]=nil elseif h1 then y[a1]=nil local g1,f1=pcall(h1,a1)if not g1 then z.termSig=a1 if d1.canonical then d1.canonical.termSig=a1;d1.canonical.status="error";d1.canonical.error=f1 end b1=true end else local e1=c.defaultAction(a1)if e1=="term"then z.termSig=a1 if d1.canonical then d1.canonical.termSig=a1 end b1=true y[a1]=nil elseif e1=="stop"then if not z.stopped then z.stopped=true z.stopSig=a1 if d1.canonical then d1.canonical.status="stopped"end end y[a1]=nil elseif e1=="cont"then y[a1]=nil else y[a1]=nil end end end end if b1 then return"dead"end if z.stopped then return"stop"end return"run"end function a.dumpTree()local y={}local function z(d1,b1)local a1=b[d1]if not a1 then return end y[#y+1]=string.rep("  ",b1)..string.format("#%d %s (ppid=%d, %s, pgrp=%d, sid=%d, sig=%s)",d1,a1.name or"?",a1.ppid,a1.status or"?",a1.pgrp or 0,a1.sid or 0,a1.termSig and c.name(a1.termSig)or"-")local c1=d[d1]if c1 then for e1 in pairs(c1)do z(e1,b1+1)end end end z(1,0)return table.concat(y,"\n")end local h=p.syscalls()h["signal.kill"]=function(y,z)return a.kill(y,z)end h["signal.killpg"]=function(y,z)return a.signalGroup(y,z)end h["signal.install"]=function(y,z)return a.setHandler(y,z)end h["signal.list"]=function()return c.listNumbers()end h["signal.name"]=function(y)return c.name(y)end h["signal.number"]=function(y)return c.number(y)end h["sig.name"]=function(y)return c.name(y)end h["sig.list"]=function()return c.listNumbers()end h["sig.number"]=function(y)return c.number(y)end h["job.setsid"]=function()return a.setsid()end h["job.setpgid"]=function(z,y)return a.setpgid(z,y)end h["job.tcsetpgrp"]=function(y,z)return a.tcsetpgrp(y,z)end h["job.tcgetpgrp"]=function(y)return a.tcgetpgrp(y)end h["job.group"]=function()return a.currentGroup()end h["job.sessfor"]=function(y)return a.sessionForTty(y)end h["umask.get"]=function()return a.current().umask or tonumber("022",8)end h["umask.set"]=function(y)local z=a.current()local b1=b[z.pid]if not b1 then return nil,"umask: no such process"end if type(y)~="number"or y<0 or y>tonumber("777",8)then return nil,"umask: mask out of range (0..0777)"end local a1=b1.umask or tonumber("022",8)b1.umask=math.floor(y)return a1 end local function l()return require("kernel.vfs_api").fs end local function i(y,z)if y:find("/",1,true)then return y end for b1 in tostring(z or"/bin"):gmatch("[^:]+")do local a1=(b1=="/"and""or b1).."/"..y if l().exists(a1)then return a1 end end return nil end local function m(y)if y:sub(1,2)~="#!"then return nil,nil end local a1=y:sub(3):gsub("^[ \t]+","")local z=a1:match("^(%S+)")if not z then return nil,nil end local arg=a1:match("^%S+[ \t]+(.-)[ \t]*$")return z,arg end local function n(y)local a1,z=l().open(y,"r")if not a1 then return nil,z end local b1=a1.readAll()or""a1.close()return b1 end function a.exec(k1,f1,z)z=z or{}local h1=a.current()local c1=b[h1.pid]local e1=(c1 and c1.envvars and c1.envvars.PATH)or"/bin"local a1=i(k1,e1)if not a1 then return nil,k1..": command not found"end if not l().canExecute(a1)then return nil,a1..": permission denied"end local j1,s1=n(a1)if not j1 then return nil,a1..": "..tostring(s1)end local d1,q1=m(j1:match("^([^\n]*)")or"")local y={[0]=a1}if d1 then local g1,arg=d1,q1 if d1:match("[^/]+$")=="env"then if not arg or arg==""then return nil,"shebang: env without a program"end g1=arg:match("^(%S+)")arg=arg:match("^%S+%s+(.*)$")end local b1=i(g1,e1)if not b1 then return nil,"shebang interpreter not found: "..g1 end if not l().canExecute(b1)then return nil,"shebang interpreter not executable: "..g1 end local i1,r1=n(b1)if not i1 then return nil,"shebang interpreter: "..tostring(r1)end local l1=0 y={[0]=b1}if arg and arg~=""then l1=1;y[l1]=arg end l1=l1+1;y[l1]=a1 for u1=1,#(f1 or{})do l1=l1+1;y[l1]=f1[u1]end local n1,v1,o1=a.spawn(i1,b1,h1.pid,z.uid,z.gid,y,z)if not n1 then return nil,tostring(o1)end return n1 end for t1=1,#(f1 or{})do y[t1]=f1[t1]end local m1,w1,p1=a.spawn(j1,a1,h1.pid,z.uid,z.gid,y,z)if not m1 then return nil,tostring(p1)end return m1 end h["proc.exec"]=function(a1,y,z)return a.exec(a1,y,z)end k.setSignalCheck(a.applySignals)return a end __chunks["kernel.procfs"]=function()local _ENV=setmetatable({require=__require},{__index=_G})local x=require("kernel.vfs")local b=require("kernel.process")local s={}local r=0 local c="0.0.0"local e={"cmdline","comm","cwd","stat","status"}local f={"mounts","uptime","version"}local function t(y)return(y or""):gsub("^/+","")end local function g(z)local y=z.name or("proc#"..z.pid)return y:match("([^/]+)$")or y end local function m(y)if y.status=="stopped"then return"T","stopped"end if y.pid==b.current().pid then return"R","running"end return"S","sleeping"end local function w(z)local y=b.ttyFor(z.pid)if not y then return"0",-1 end return(y:gsub("^/dev/","")),(b.fgPgrpFor(z.pid)or-1)end local function u(a1)local y=m(a1)local b1,z=w(a1)return string.format("%d (%s) %s %d %d %d %s %d\n",a1.pid,g(a1),y,a1.ppid or 0,a1.pgrp or 0,a1.sid or 0,b1,z)end local function p(z)local y,a1=m(z)return table.concat({"Name:\t"..g(z),"State:\t"..y.." ("..a1..")","Tgid:\t"..z.pid,"Pid:\t"..z.pid,"PPid:\t"..(z.ppid or 0),"Pgrp:\t"..(z.pgrp or 0),"Session:\t"..(z.sid or 0),"Uid:\t"..(z.uid or 0),"Gid:\t"..(z.gid or 0),},"\n").."\n"end local function h(b1)local y=b1.argv or{}if y[0]==nil and#y==0 then return""end local z={}for a1=0,#y do z[#z+1]=tostring(y[a1])end return table.concat(z,"\0").."\0"end local function o()local y={}for d1,a1 in ipairs(x.list())do local b1=(a1.meta and a1.meta.device)or"none"local c1=(a1.meta and a1.meta.fstype)or"none"local z=a1.backend.isReadOnly("")and"ro"or"rw"y[#y+1]=string.format("%s %s %s %s 0 0",b1,a1.root,c1,z)end return table.concat(y,"\n").."\n"end local function q()return string.format("%.2f\n",(os.epoch("utc")-r)/1000)end local function l()return"Delin OS "..c.." ("..tostring(os.version())..", ".._VERSION..")\n"end local function d(a1)a1=t(a1):gsub("/+$","")if a1==""then return"root"end local y={}for e1 in a1:gmatch("[^/]+")do y[#y+1]=e1 end local z=y[1]if z=="self"then local b1=b.current().pid if not b1 or b1==0 then return nil end z=tostring(b1)end if z:match("^%d+$")then local c1=tonumber(z)if#y==1 then return"pid",c1 end if#y==2 then return"pidfile",c1,y[2]end return nil end if#y==1 then for f1,d1 in ipairs(f)do if d1==z then return"sysfile",nil,z end end end return nil end local function a(y)local z=b.info(y)if not z then return nil end if z.status~="running"and z.status~="stopped"then return nil end return z end local function n(z)local y=b.current().uid or 0 return y==0 or y==z.uid end local function j(z,y)if y=="comm"then return g(z).."\n"end if y=="stat"then return u(z)end if y=="status"then return p(z)end if y=="cmdline"then return h(z)end if y=="cwd"then if not n(z)then return nil,"permission denied"end return(z.cwd or"/").."\n"end return nil,"no such file: "..tostring(y)end local function k(y)if y=="uptime"then return q()end if y=="version"then return l()end if y=="mounts"then return o()end return nil,"no such file: "..tostring(y)end local function i(y)local z=1 return{read=function(d1,c1)if z>#y then return nil end if type(c1)~="number"then local b1=y:sub(z)z=#y+1 return b1 end local a1=y:sub(z,z+c1-1)z=z+#a1 return a1 end,readLine=function()if z>#y then return nil end local b1=y:find("\n",z,true)if not b1 then local c1=y:sub(z)z=#y+1 return c1 end local a1=y:sub(z,b1-1)z=b1+1 return a1 end,readAll=function()if z>#y then return nil end local a1=y:sub(z)z=#y+1 return a1 end,write=function()return nil,"read-only fs"end,writeLine=function()return nil,"read-only fs"end,close=function()end,flush=function()return true end,}end local v={kind="virtual",list=function(c1)local z,b1=d(c1)if z=="root"then local y={}for i1,g1 in ipairs(b.list())do y[#y+1]=tostring(g1.pid)end y[#y+1]="self"for h1,e1 in ipairs(f)do y[#y+1]=e1 end return y end if z=="pid"then if not a(b1)then return nil end local a1={}for d1,f1 in ipairs(e)do a1[d1]=f1 end return a1 end return nil end,exists=function(b1)local y,z,a1=d(b1)if y=="root"or y=="sysfile"then return true end if y=="pid"then return a(z)~=nil end if y=="pidfile"then if not a(z)then return false end for d1,c1 in ipairs(e)do if c1==a1 then return true end end return false end return false end,isDir=function(a1)local y,z=d(a1)if y=="root"then return true end if y=="pid"then return a(z)~=nil end return false end,attributes=function(b1)local y,a1,z=d(b1)if y=="root"then return{size=0,isDir=true,isReadOnly=true,name="proc"}end if y=="pid"then if not a(a1)then return nil end return{size=0,isDir=true,isReadOnly=true,name=tostring(a1)}end if y=="pidfile"then if not backend.exists(b1)then return nil end return{size=0,isDir=false,isReadOnly=true,name=z}end if y=="sysfile"then return{size=0,isDir=false,isReadOnly=true,name=z}end return nil end,getSize=function()return 0 end,getDrive=function()return"proc"end,getFreeSpace=function()return 0 end,getCapacity=function()return 0 end,isReadOnly=function()return true end,open=function(d1,b1)local z,e1,c1=d(d1)if z=="root"or z=="pid"then return nil,"is a directory"end if not z then return nil,"no such path: /proc/"..t(d1)end if b1 and b1:find("w")then return nil,"read-only fs: /proc/"..t(d1)end local y,a1 if z=="pidfile"then local f1=a(e1)if not f1 then return nil,"no such process: "..tostring(e1)end y,a1=j(f1,c1)else y,a1=k(c1)end if y==nil then return nil,a1 end return i(y)end,makeDir=function()error("read-only fs",2)end,move=function()error("read-only fs",2)end,copy=function()error("read-only fs",2)end,delete=function()error("read-only fs",2)end,}function s.mount(z,y)r=z or os.epoch("utc")c=y or c x.mount("/proc",v,{device="proc",fstype="proc"})return true end return s end __chunks["kernel.scheduler"]=function()local _ENV=setmetatable({require=__require},{__index=_G})local f=require("kernel.tty")local a={}local b={}local c=nil function a.setSignalCheck(g)c=g end local d=nil function a.setDiskHook(g)d=g end function a.addProcess(g)b[#b+1]=g end local function e(g)if g[1]=="char"or g[1]=="paste"then f.feedInput(g)elseif g[1]=="key"or g[1]=="key_up"then f.routeKey(g)elseif(g[1]=="disk"or g[1]=="disk_eject")and d then d(g)end end function a.run()local j={n=0}local l=os.startTimer(0.5)local m=os.startTimer(0.05)local n=false local h=false while#b>0 do local p=1 n=false h=false while p<=#b do local g=b[p]if not n then n=true if j[1]=="timer"then if j[2]==l then f.blinkTick()l=os.startTimer(0.5)h=true elseif j[2]==m then m=os.startTimer(0.05)h=true end end e(j)end local o="run"if c then o=c(g)end if o=="dead"then g.status="dead";g.dead=true if g.onExit then g.onExit(g,"dead",nil)end table.remove(b,p)elseif o=="stop"then p=p+1 else local i if not g.started or j[1]=="terminate"then i=true elseif g.filter==nil then i=true elseif g.filter==j[1]then i=not h else i=false end if i then local q,k if not g.started then g.started=true q,k=coroutine.resume(g.co)else q,k=coroutine.resume(g.co,table.unpack(j,1,j.n))end if not q then g.status="error";g.error=k;g.dead=true if g.onExit then g.onExit(g,"error",k)end table.remove(b,p)elseif coroutine.status(g.co)=="dead"then g.status="dead";g.dead=true if g.onExit then g.onExit(g,"dead",nil,k)end table.remove(b,p)else g.filter=k p=p+1 end else p=p+1 end end end if#b>0 then j=table.pack(os.pullEventRaw())end end end return a end __chunks["kernel.signal"]=function()local _ENV=setmetatable({require=__require},{__index=_G})local a={}a.SIGHUP=1 a.SIGINT=2 a.SIGQUIT=3 a.SIGKILL=9 a.SIGUSR1=10 a.SIGUSR2=12 a.SIGPIPE=13 a.SIGALRM=14 a.SIGTERM=15 a.SIGCHLD=17 a.SIGCONT=18 a.SIGSTOP=19 a.SIGTSTP=20 a.SIGTTIN=21 a.SIGTTOU=22 local e={[a.SIGHUP]="HUP",[a.SIGINT]="INT",[a.SIGQUIT]="QUIT",[a.SIGKILL]="KILL",[a.SIGUSR1]="USR1",[a.SIGUSR2]="USR2",[a.SIGPIPE]="PIPE",[a.SIGALRM]="ALRM",[a.SIGTERM]="TERM",[a.SIGCHLD]="CHLD",[a.SIGCONT]="CONT",[a.SIGSTOP]="STOP",[a.SIGTSTP]="TSTP",[a.SIGTTIN]="TTIN",[a.SIGTTOU]="TTOU",}local c={}local b={}for h,g in ipairs({a.SIGHUP,a.SIGINT,a.SIGQUIT,a.SIGKILL,a.SIGUSR1,a.SIGUSR2,a.SIGPIPE,a.SIGALRM,a.SIGTERM,a.SIGCHLD,a.SIGCONT,a.SIGSTOP,a.SIGTSTP,a.SIGTTIN,a.SIGTTOU})do c[#c+1]=g b[#b+1]=e[g]end local f={[a.SIGHUP]="term",[a.SIGINT]="term",[a.SIGQUIT]="term",[a.SIGKILL]="term",[a.SIGUSR1]="term",[a.SIGUSR2]="term",[a.SIGPIPE]="term",[a.SIGALRM]="term",[a.SIGTERM]="term",[a.SIGCHLD]="ign",[a.SIGCONT]="cont",[a.SIGSTOP]="stop",[a.SIGTSTP]="stop",[a.SIGTTIN]="stop",[a.SIGTTOU]="stop",}local d={[a.SIGKILL]=true,[a.SIGSTOP]=true}function a.name(i)return e[i]or("SIG"..tostring(i))end function a.number(j)local i=(j or""):upper()i=i:gsub("^SIG","")for l,k in pairs(e)do if k==i then return l end end return nil end function a.defaultAction(i)return f[i]or"term"end function a.catchable(i)return not d[i]end function a.listNumbers()return c end function a.listNames()return b end return a end __chunks["kernel.sysfs"]=function()local _ENV=setmetatable({require=__require},{__index=_G})local n=require("kernel.vfs")local c=require("kernel.display")local i={}local f="class"local a={}function i.registerClass(o,p)a[o]=p end function i.unregisterClass(o)a[o]=nil end local function m(o)return(o or""):gsub("^/+","")end local function g(p)p=m(p)if p==""then return"root"end local o={}for q in p:gmatch("[^/]+")do o[#o+1]=q end if o[1]~=f then return nil end if#o==1 then return"class"end if#o==2 then return"classdir",o[2]end if#o==3 then return"entry",o[2],o[3]end if#o==4 then return"attr",o[2],o[3],o[4]end return nil end local function b(q,o)local p=a[q]if not p then return false end for s,r in ipairs(p.list())do if r==o then return true end end return false end local function d(q,p,s)local r=a[q]if not r or not b(q,p)then return false end local o=r.attrs(p)if not o then return false end for u,t in ipairs(o)do if t==s then return true end end return false end local function e(r,o,q)local p=a[r]if not p or not p.set then return false end if not d(r,o,q)then return false end if p.writable then return p.writable(o,q)and true or false end return true end local function k(t,r,s)local u=a[t]local p=0 local function o()return u.get(r,s)or""end local function q(x)if not e(t,r,s)then return nil,"read-only attribute"end local y=x:gsub("[\r\n]+$","")local w,v=u.set(r,s,y)if w then return#x else return nil,v end end return{read=function(y,x)local w=o()if p>=#w then return nil end if type(x)~="number"then p=#w;return w end local v=w:sub(p+1,p+x)p=p+#v return v end,readLine=function()if p>=#o()then return nil end p=#o()return o()end,readAll=function()if p>=#o()then return nil end p=#o()return o()end,write=function(self,v)return q(v)end,writeLine=function(self,v)return q(v.."\n")end,close=function()end,flush=function()return true end,}end local l={kind="virtual",list=function(t)local o,r,p=g(t)if o=="root"then return{f}end if o=="class"then local q={}for u in pairs(a)do q[#q+1]=u end table.sort(q)return q end if o=="classdir"then local s=a[r]if not s then return nil end return s.list()end if o=="entry"then if not b(r,p)then return nil end return a[r].attrs(p)end return nil end,exists=function(s)local o,q,p,r=g(s)if o=="root"or o=="class"then return true end if o=="classdir"then return a[q]~=nil end if o=="entry"then return b(q,p)end if o=="attr"then return d(q,p,r)end return false end,isDir=function(r)local o,q,p=g(r)if o=="root"or o=="class"then return true end if o=="classdir"then return a[q]~=nil end if o=="entry"then return b(q,p)end return false end,attributes=function(s)local p,q,o,r=g(s)if p=="root"then return{size=0,isDir=true,isReadOnly=true,name="sys"}end if p=="class"then return{size=0,isDir=true,isReadOnly=true,name=f}end if p=="classdir"then if not a[q]then return nil end return{size=0,isDir=true,isReadOnly=true,name=q}end if p==nil then return nil end if p=="entry"then if not b(q,o)then return nil end return{size=0,isDir=true,isReadOnly=true,name=o}end if not d(q,o,r)then return nil end return{size=0,isDir=false,isReadOnly=not e(q,o,r),name=r}end,getSize=function()return 0 end,getDrive=function()return"sys"end,getFreeSpace=function()return 0 end,getCapacity=function()return 0 end,isReadOnly=function(s)local q,r,o,p=g(s)if q~="attr"then return true end return not e(r,o,p)end,open=function(t,s)local r,q,o,p=g(t)if r~="attr"then if r then return nil,"is a directory"end return nil,"no such path: /sys/"..m(t)end if not d(q,o,p)then return nil,"no such attribute: "..q.."/"..tostring(o).."/"..tostring(p)end if s and s:find("w")and not e(q,o,p)then return nil,"read-only attribute: "..p end return k(q,o,p)end,makeDir=function()error("read-only fs",2)end,move=function()error("read-only fs",2)end,copy=function()error("read-only fs",2)end,delete=function()error("read-only fs",2)end,}local function j(p)local q=c.byName(p)if not q then return nil end local o={"name","type","size"}if q.listConfig then for s,r in ipairs(q.listConfig())do o[#o+1]=r end end return o end local function h(p,o)if o=="name"or o=="type"or o=="size"then return false end local q=c.byName(p)if not(q and q.listConfig and q.setConfig)then return false end for s,r in ipairs(q.listConfig())do if r==o then return true end end return false end i.registerClass("display",{list=function()local o={}for r,q in ipairs(c.list())do local p=c.get(q)if p and p.name then o[#o+1]=p.name end end return o end,attrs=j,writable=h,get=function(p,o)local q=c.byName(p)if not q then return nil end if o=="name"then return q.name or q.id end if o=="type"then return tostring(q.type or"")end if o=="size"then local s,r=q.getSize()return tostring(s).."x"..tostring(r)end if q.getConfig then return q.getConfig(o)end return nil end,set=function(o,q,p)local r=c.byName(o)if not r then return nil,"no such display: "..o end local u,t=r.getSize()local x,s=r.setConfig(q,p)if x then local w,v=r.getSize()if u~=w or t~=v then c.resize(r.id)end return true end return nil,s end,})function i.mount()n.mount("/sys",l,{device="sysfs",fstype="sysfs"})return true end return i end __chunks["kernel.tty"]=function()local _ENV=setmetatable({require=__require},{__index=_G})local l1=require("kernel.signal")local f={}f.onSignal=nil f.readGuard=nil local t=0 local c={}local d=nil local u={[0x0]=0x000000,[0x1]=0xB300B3,[0x2]=0x3344CC,[0x3]=0x66CCCC,[0x4]=0x4CBB4C,[0x5]=0x66CC33,[0x6]=0x7F3300,[0x7]=0xCC3333,[0x8]=0x4C4C4C,[0x9]=0x999999,[0xa]=0xE96699,[0xb]=0xE6E633,[0xc]=0xE69C33,[0xd]=0xE64CE6,[0xe]=0x99CCFF,[0xf]=0xFFFFFF,}local p1={[0x0]=0xf,[0x1]=0xa,[0x2]=0xb,[0x3]=0x9,[0x4]=0xd,[0x5]=0x5,[0x6]=0xc,[0x7]=0xe,[0x8]=0x7,[0x9]=0x8,[0xa]=0x6,[0xb]=0x4,[0xc]=0x1,[0xd]=0x2,[0xe]=0x3,[0xf]=0x0,}local g1={[0xf]=0x1,[0xc]=0x2,[0xd]=0x4,[0xe]=0x8,[0xb]=0x10,[0x5]=0x20,[0xa]=0x40,[0x8]=0x80,[0x9]=0x100,[0x3]=0x200,[0x1]=0x400,[0x2]=0x800,[0x6]=0x1000,[0x4]=0x2000,[0x7]=0x4000,[0x0]=0x8000,}local g,h=0xf,0x0 local l={[1]=0x0,[2]=0x7,[3]=0x4,[4]=0x6,[5]=0x2,[6]=0x1,[7]=0x3,[8]=0x9,[9]=0x8,[10]=0xa,[11]=0x5,[12]=0xb,[13]=0xe,[14]=0xd,[15]=0x3,[16]=0xf,}local v1={[0x0]=0x8,[0x7]=0xa,[0x4]=0x5,[0x6]=0xb,[0x2]=0xe,[0x1]=0xd,[0x3]=0x3,[0x9]=0xf,}local function q1(w1)return w1.bold and(v1[w1.fg]or w1.fg)or w1.fg end local function s1(x1)local c2,b2=x1.getSize()local w1 if x1.mode=="term"then w1={dev=x1,mode="term",cols=math.floor(c2),rows=math.floor(b2),cellW=1,cellH=1}else local a2=x1.cellW local z1=x1.cellH w1={dev=x1,mode="pixel",cols=math.floor(c2/a2),rows=math.floor(b2/z1),cellW=a2,cellH=z1,}end local e2=w1.cols*w1.rows local y1={}for d2=1,e2 do y1[d2]={ch=" ",fg=g,bg=h}end w1.grid=y1 w1.cursorX,w1.cursorY=0,0 w1.fg,w1.bg=g,h w1.dirty={}w1.dirtyList={}w1.closed=false w1.inputBuffer=""w1.lineQueue={}w1.echo=true w1.eof=false w1.intr=false w1.reading=false w1.cursorOn=true w1.cursorHidden=false w1.cursorRenderedIdx=nil w1.escState=nil w1.escParams=""w1.escInter=""w1.bold=false w1.reverse=false w1.saved=nil return w1 end local function p(w1)return w1.cursorOn and not w1.cursorHidden end local function j(w1,x1)if not w1.dirty[x1]then w1.dirty[x1]=true w1.dirtyList[#w1.dirtyList+1]=x1 end end local function m1(w1,x1)return(x1-1)==w1.cursorY*w1.cols+w1.cursorX end local function a(w1)local y1=w1.cursorRenderedIdx local x1=p(w1)and(w1.cursorY*w1.cols+w1.cursorX+1)or nil if y1 then j(w1,y1)end if x1 then j(w1,x1)end w1.cursorRenderedIdx=x1 end local function k1(w1)for y1=0,w1.rows-2 do for x1=0,w1.cols-1 do w1.grid[y1*w1.cols+x1+1]=w1.grid[(y1+1)*w1.cols+x1+1]end end for z1=0,w1.cols-1 do w1.grid[(w1.rows-1)*w1.cols+z1+1]={ch=" ",fg=q1(w1),bg=w1.bg,rev=w1.reverse}end for a2=1,w1.rows*w1.cols do j(w1,a2)end w1.cursorRenderedIdx=nil a(w1)end local function k(w1,x1)if x1=="\n"then w1.cursorY=w1.cursorY+1 w1.cursorX=0 elseif x1=="\r"then w1.cursorX=0 a(w1)return elseif x1=="\b"then if w1.cursorX>0 then w1.cursorX=w1.cursorX-1 end a(w1)return elseif x1=="\t"then w1.cursorX=math.floor(w1.cursorX/8+1)*8 else local y1=w1.cursorY*w1.cols+w1.cursorX+1 if y1<=w1.rows*w1.cols then w1.grid[y1]={ch=x1,fg=q1(w1),bg=w1.bg,rev=w1.reverse}j(w1,y1)end w1.cursorX=w1.cursorX+1 end if w1.cursorY>=w1.rows then if w1.cursorY>w1.rows-1 then w1.cursorY=w1.rows-1 if w1.cursorX>w1.cols-1 then w1.cursorX=w1.cols-1 end k1(w1)end elseif w1.cursorX>=w1.cols then w1.cursorX=0 w1.cursorY=w1.cursorY+1 if w1.cursorY>=w1.rows then w1.cursorY=w1.rows-1 k1(w1)end end a(w1)end local function b(w1)local y1=w1.dev for j2,a2 in ipairs(w1.dirtyList)do local x1=w1.grid[a2]local c2=(a2-1)%w1.cols local e2=math.floor((a2-1)/w1.cols)local b2,z1=x1.fg,x1.bg if x1.rev then b2,z1=z1,b2 end if m1(w1,a2)and p(w1)then b2,z1=z1,b2 end if w1.mode=="term"then y1.text(c2,e2,x1.ch,p1[b2],p1[z1])else local f2=c2*w1.cellW local g2=e2*w1.cellH y1.rect(f2,g2,w1.cellW,w1.cellH,u[z1])local i2=f2 if y1.getTextWidth then local h2=y1.getTextWidth(x1.ch)local d2=math.floor((w1.cellW-h2)/2)if d2>0 then i2=i2+d2 end end y1.text(i2,g2,x1.ch,u[b2],u[z1])end end w1.dirty={}w1.dirtyList={}y1.flush()end local function r(w1)return{ch=" ",fg=g,bg=w1.bg}end local function m(w1)for x1=1,w1.rows*w1.cols do w1.grid[x1]=r(w1)end if w1.mode=="term"then w1.dev.fill(g1[w1.bg])else w1.dev.fill(u[w1.bg])end w1.dev.flush()w1.dirty={}w1.dirtyList={}w1.cursorRenderedIdx=nil end local function w(w1)w1.saved={x=w1.cursorX,y=w1.cursorY,fg=w1.fg,bg=w1.bg,bold=w1.bold,reverse=w1.reverse,}end local function q(w1)local x1=w1.saved if not x1 then return end w1.cursorX,w1.cursorY=x1.x,x1.y w1.fg,w1.bg,w1.bold,w1.reverse=x1.fg,x1.bg,x1.bold,x1.reverse a(w1)end local function e(w1,x1,y1)w1.cursorX=math.max(0,math.min(w1.cols-1,x1))w1.cursorY=math.max(0,math.min(w1.rows-1,y1))a(w1)end local function y(w1,y1)local c2=w1.rows*w1.cols if y1==2 then m(w1)a(w1)b(w1)return end local z1=w1.cursorY*w1.cols+w1.cursorX+1 local x1,a2=z1,c2 if y1==1 then x1,a2=1,z1 end for b2=x1,a2 do w1.grid[b2]=r(w1)j(w1,b2)end a(w1)end local function c1(w1,y1)local a2=w1.cursorY*w1.cols local x1,b2=w1.cursorX,w1.cols-1 if y1==1 then x1,b2=0,w1.cursorX elseif y1==2 then x1,b2=0,w1.cols-1 end for c2=x1,b2 do local z1=a2+c2+1 w1.grid[z1]=r(w1)j(w1,z1)end a(w1)end local function t1(w1,y1)for z1=1,#y1 do local x1=y1[z1]if x1==0 then w1.fg,w1.bg,w1.bold,w1.reverse=g,h,false,false elseif x1==1 then w1.bold=true elseif x1==7 then w1.reverse=true elseif x1==22 then w1.bold=false elseif x1==27 then w1.reverse=false elseif x1>=30 and x1<=37 then w1.fg=l[x1-29]elseif x1==39 then w1.fg=g elseif x1>=40 and x1<=47 then w1.bg=l[x1-39]elseif x1==49 then w1.bg=h elseif x1>=90 and x1<=97 then w1.fg=l[x1-81]elseif x1>=100 and x1<=107 then w1.bg=l[x1-91]end end end local function j1(w1)w1.fg,w1.bg,w1.bold,w1.reverse=g,h,false,false w1.cursorHidden=false w1.saved=nil m(w1)w1.cursorX,w1.cursorY=0,0 a(w1)b(w1)end local function d1(y1)local w1={}for x1 in(y1..";"):gmatch("([^;]*);")do w1[#w1+1]=tonumber(x1)or 0 end return w1 end local function i(w1)return(w1 and w1~=0)and w1 or 1 end local function i1(w1,x1,b2,z1,a2)if#a2>0 then return end local y1,c2=z1[1],z1[2]if x1=="m"then t1(w1,z1)elseif x1=="J"then y(w1,y1)elseif x1=="K"then c1(w1,y1)elseif x1=="H"or x1=="f"then e(w1,i(c2)-1,i(y1)-1)elseif x1=="A"then e(w1,w1.cursorX,w1.cursorY-i(y1))elseif x1=="B"then e(w1,w1.cursorX,w1.cursorY+i(y1))elseif x1=="C"then e(w1,w1.cursorX+i(y1),w1.cursorY)elseif x1=="D"then e(w1,w1.cursorX-i(y1),w1.cursorY)elseif x1=="E"then e(w1,0,w1.cursorY+i(y1))elseif x1=="F"then e(w1,0,w1.cursorY-i(y1))elseif x1=="G"then e(w1,i(y1)-1,w1.cursorY)elseif x1=="d"then e(w1,w1.cursorX,i(y1)-1)elseif x1=="s"then w(w1)elseif x1=="u"then q(w1)elseif b2=="?"and y1==25 then w1.cursorHidden=(x1=="l")a(w1)end end local function o1(w1,x1)local a2=w1.escState if a2==nil then if x1=="\27"then w1.escState,w1.escParams,w1.escInter="esc","",""else k(w1,x1)end return end local c2=string.byte(x1)if a2=="esc"then if x1=="["then w1.escState="csi"elseif x1=="]"then w1.escState="osc"elseif x1=="("or x1==")"or x1=="*"or x1=="+"then w1.escState="charset"elseif x1=="7"then w1.escState=nil;w(w1)elseif x1=="8"then w1.escState=nil;q(w1)elseif x1=="c"then w1.escState=nil;j1(w1)else w1.escState=nil end elseif a2=="charset"then w1.escState=nil elseif a2=="osc"then if x1=="\7"then w1.escState=nil elseif x1=="\27"then w1.escState="osc_esc"end elseif a2=="osc_esc"then w1.escState=nil elseif c2>=0x30 and c2<=0x3f then w1.escParams=w1.escParams..x1 elseif c2>=0x20 and c2<=0x2f then w1.escInter=w1.escInter..x1 elseif c2>=0x40 and c2<=0x7e then w1.escState=nil local b2,z1=w1.escParams,""local y1=b2:match("^([?<>=])")if y1 then z1=y1;b2=b2:sub(2)end i1(w1,x1,z1,d1(b2),w1.escInter)else w1.escState=nil end end local function n1(w1,x1)k(w1,x1)b(w1)end local function o(w1)if#w1.inputBuffer>0 then w1.inputBuffer=w1.inputBuffer:sub(1,-2)if w1.echo and w1.cursorX>0 then k(w1,"\b")k(w1," ")k(w1,"\b")b(w1)end end end local function s(w1)k(w1,"\n")b(w1)w1.lineQueue[#w1.lineQueue+1]=w1.inputBuffer w1.inputBuffer=""end local function h1(w1)w1.lineQueue[#w1.lineQueue+1]=w1.inputBuffer w1.inputBuffer=""end local function b1(w1,y1)for x1=1,#y1 do k(w1,y1:sub(x1,x1))end b(w1)end local function z(w1)w1.inputBuffer=""w1.eof=false if w1.reading then w1.intr=true end end local function a1(w1,x1)local y1=string.byte(x1 or"",1)if y1 and y1<0x20 and y1~=0x0A and y1~=0x0D and y1~=0x08 and y1~=0x09 then return end if x1=="\n"or x1=="\r"then s(w1)elseif x1=="\b"then o(w1)else w1.inputBuffer=w1.inputBuffer..x1 if w1.echo then n1(w1,x1)end end end local function e1(z1,x1,y1)if y1 then return end local w1=keys.getName(x1)if w1=="backspace"then o(z1)elseif w1=="enter"or w1=="return"or w1=="keypadenter"or w1=="keypad_enter"then s(z1)end end local n,x=false,false local f1={one=1,two=2,three=3,four=4,five=5,six=6,seven=7,eight=8,nine=9,zero=0}local function r1(w1)return w1=="leftCtrl"or w1=="rightCtrl"end local function u1(w1)return w1=="leftAlt"or w1=="rightAlt"end function f.routeKey(x1)local b2=x1[1]local a2=x1[2]local w1=keys.getName(a2)if not w1 then return end if r1(w1)then n=(b2=="key")return elseif u1(w1)then x=(b2=="key")return end if b2~="key"then return end if n and x then local c2=f1[w1]if c2 then local y1="tty"..tostring(c2-1)if c[y1]then f.setFocus(y1)end return end end if n and not x then if w1=="c"then if d and c[d]then f.ctrlC(c[d])end return elseif w1=="d"then if d and c[d]then f.ctrlD(c[d])end return elseif w1=="z"then if d and c[d]then f.ctrlZ(c[d])end return else return end end local z1=d and c[d]if z1 then e1(z1,a2,x1[3]or false)end end function f.feedInput(w1)local x1=d and c[d]if not x1 then return end local z1=w1[1]if z1=="char"then if n then return end a1(x1,tostring(w1[2]or""))elseif z1=="key"then e1(x1,w1[2],w1[3])elseif z1=="paste"then local y1=tostring(w1[2]or"")for a2=1,#y1 do a1(x1,y1:sub(a2,a2))end end end function f.raiseSignal(w1)if f.onSignal then f.onSignal(w1)end end function f.ctrlC(w1)if w1.echo then b1(w1,"^C\n")end z(w1)f.raiseSignal(l1.SIGINT)end function f.ctrlD(w1)if#w1.inputBuffer>0 then h1(w1)else w1.eof=true end end function f.ctrlZ(w1)if w1.echo then b1(w1,"^Z\n")end z(w1)f.raiseSignal(l1.SIGTSTP)end function f.setFocus(w1)if w1=="console"then d=nil for x1 in pairs(c)do if not d then d=x1 end end elseif c[w1]then d=w1 end return d end function f.getFocus()return d end local function v(w1,y1)local x1={isTTY=true,write=function(self,z1)if w1.closed then return nil,"device closed"end z1=tostring(z1 or"")for a2=1,#z1 do o1(w1,z1:sub(a2,a2))end b(w1)return#z1 end,writeLine=function(self,z1)if w1.closed then return nil,"device closed"end self:write((z1==nil or z1=="")and""or tostring(z1))self:write("\n")return(z1 and#z1 or 0)+1 end,clear=function(self,z1)if w1.closed then return nil,"device closed"end w1.bg=z1 or w1.bg m(w1)w1.cursorX,w1.cursorY=0,0 a(w1)b(w1)return true end,setCursor=function(self,z1,a2)if w1.closed then return nil,"device closed"end w1.cursorX=math.max(0,math.min(w1.cols-1,math.floor(z1 or 0)))w1.cursorY=math.max(0,math.min(w1.rows-1,math.floor(a2 or 0)))a(w1)b(w1)return true end,setTextColor=function(self,z1)w1.fg=z1;return true end,setBackgroundColor=function(self,z1)w1.bg=z1;return true end,setEcho=function(self,z1)w1.echo=(z1~=false);return true end,getCursor=function()return w1.cursorX,w1.cursorY end,getSize=function()return w1.cols,w1.rows end,getDeviceName=function()return w1.name end,flush=function()b(w1);return true end,close=function()return true end,}x1.readLine=function()if w1.closed then return nil,"device closed"end w1.reading=true while true do if f.readGuard and f.readGuard(w1.name)then os.pullEvent()elseif w1.eof then w1.eof=false w1.reading=false return nil elseif w1.intr then w1.intr=false w1.inputBuffer=""w1.reading=false return""elseif#w1.lineQueue>0 then local z1=table.remove(w1.lineQueue,1)w1.inputBuffer=""w1.reading=false return z1 else os.pullEvent()end end end x1.read=function()if w1.closed then return nil,"device closed"end return x1.readLine()end return x1 end function f.registerDevice(z1)local w1="tty"..t t=t+1 local x1=s1(z1)x1.name=w1 c[w1]=x1 if not d then d=w1 end local y1={writable=true,open=function(a2)return v(x1,a2)end,getCtx=function()return x1 end,}return w1,y1 end function f.get(w1)return c[w1]end function f.open(w1,y1)local x1=c[w1]if not x1 then return nil,"no such tty: "..tostring(w1)end return v(x1,y1)end function f.list()local w1={}for x1 in pairs(c)do w1[#w1+1]=x1 end table.sort(w1)return w1 end function f.resize(d2)local w1=c[d2]if not w1 then return end local b2=w1.dev local j2,h2=b2.getSize()local x1,y1 if b2.mode=="term"then x1=math.floor(j2)y1=math.floor(h2)else local f2=b2.cellW local e2=b2.cellH x1=math.floor(j2/f2)y1=math.floor(h2/e2)end local a2,c2=w1.cols,w1.rows local z1={}for k2=1,x1*y1 do z1[k2]={ch=" ",fg=g,bg=h}end for i2=0,math.min(y1,c2)-1 do for g2=0,math.min(x1,a2)-1 do z1[i2*x1+g2+1]=w1.grid[i2*a2+g2+1]end end w1.grid=z1 w1.cols,w1.rows=x1,y1 if w1.cursorX>=x1 then w1.cursorX=x1-1 end if w1.cursorY>=y1 then w1.cursorY=y1-1 end w1.dirty={}w1.dirtyList={}w1.cursorRenderedIdx=nil a(w1)for l2=1,x1*y1 do j(w1,l2)end b(w1)return true end function f.blinkTick()for x1,w1 in pairs(c)do if not w1.closed then w1.cursorOn=not w1.cursorOn a(w1)b(w1)end end end return f end __chunks["kernel.user"]=function()local _ENV=setmetatable({require=__require},{__index=_G})local a={}local m=require("kernel.modules")local f=nil pcall(function()f=require("kernel.process")end)local function n()if not f then return{uid=0,gid=0}end return f.current()end local function k(p)return(p:match("^%s*(.-)%s*$"))end function a.hash(p,r)local s=p..r local q=5381 for t=1,#s do q=((q*33)+s:byte(t))%0x100000000 end return string.format("%x",q)end function a.makeSalt(p)p=p or 8 local r="abcdefghijklmnopqrstuvwxyz0123456789"local q={}for t=1,p do local s=math.random(#r)q[t]=r:sub(s,s)end return table.concat(q)end local function h(p)return type(p)=="string"and p:match("^[%a_][%w_%-%.]*$")~=nil end local function g(p)return type(p)=="number"and p>=0 and p==math.floor(p)and p<=0xFFFFFFFF end local function c(r)local p={}for q in(r.members or""):gmatch("[^,]+")do q=k(q)if q~=""then p[#p+1]=q end end return p end local function b(t,r)local q,p={},{}for u,s in ipairs(r)do if s~=""and not q[s]then q[s]=true;p[#p+1]=s end end table.sort(p)t.members=table.concat(p,",")end local function l(q,p)return(","..(q.members or"")..","):find(","..p..",",1,true)~=nil end function a.parse(v,w,x)local u={users={},groups={},userOrder={},groupOrder={},raw={passwd=v or"",shadow=w or"",group=x or""}}for r in(v or""):gmatch("[^\r\n]+")do r=k(r)if r~=""and r:sub(1,1)~="#"then local t,m1,k1,i1,e1,f1,c1=r:match("^([^:]+):([^:]*):([^:]+):([^:]+):([^:]*):([^:]*):([^:]*)$")if t then u.users[t]={name=t,uid=tonumber(k1),gid=tonumber(i1),full=e1 or"",home=f1 or("/home/"..t),shell=c1}u.userOrder[#u.userOrder+1]=t end end end for q in(w or""):gmatch("[^\r\n]+")do q=k(q)if q~=""and q:sub(1,1)~="#"then local a1,g1=q:match("^([^:]+):(.*)$")local h1=a1 and u.users[a1]if h1 then local d1,z=g1:match("^(!*)(.*)$")h1.locked=d1~=""if z==""then h1.salt,h1.hash,h1.nopass=nil,nil,true else local b1,l1=z:match("^([^$]+)%$(%x+)$")if b1 then h1.salt,h1.hash=b1,l1 end end end end end for s in(x or""):gmatch("[^\r\n]+")do s=k(s)if s~=""and s:sub(1,1)~="#"then local p,n1,j1,y=s:match("^([^:]+):([^:]*):([^:]+):(.*)$")if p then u.groups[p]={name=p,gid=tonumber(j1),members=k(y or"")}u.groupOrder[#u.groupOrder+1]=p end end end return u end function a.serialize(r)local t,u={},{}for z,w in ipairs(r.userOrder)do local q=r.users[w]if q then t[#t+1]=string.format("%s:x:%d:%d:%s:%s:%s",w,q.uid,q.gid,q.full or"",q.home or"",q.shell or"")local p=(q.salt and q.hash)and(q.salt.."$"..q.hash)or""if q.locked then p="!"..p end u[#u+1]=w..":"..p end end local s={}for y,x in ipairs(r.groupOrder)do local v=r.groups[x]if v then s[#s+1]=string.format("%s:x:%d:%s",x,v.gid,v.members or"")end end return table.concat(t,"\n").."\n",table.concat(u,"\n").."\n",table.concat(s,"\n").."\n"end function a.verify(s,q,p)local r=s.users[q]if not r or r.locked then return false end if r.nopass then return(p or"")==""end if not r.hash then return false end return a.hash(r.salt,p or"")==r.hash end local function d(p)if not p then return nil end return{name=p.name,uid=p.uid,gid=p.gid,full=p.full or"",home=p.home,shell=p.shell,locked=p.locked or false}end function a.get(q,p)return d(q.users[p])end function a.byUid(q,p)for s,r in pairs(q.users)do if r.uid==p then return d(r)end end return nil end function a.groupByName(q,p)local r=q.groups and q.groups[p]if not r then return nil end return{name=r.name,gid=r.gid,members=r.members}end function a.groupByGid(r,p)for s,q in pairs(r.groups or{})do if q.gid==p then return{name=q.name,gid=q.gid,members=q.members}end end return nil end function a.list(q)local p={}for s,r in ipairs(q.userOrder)do if q.users[r]then p[#p+1]=d(q.users[r])end end table.sort(p,function(t,u)if t.uid==u.uid then return t.name<u.name end return t.uid<u.uid end)return p end function a.groups(q)local p={}for s,r in ipairs(q.groupOrder)do if q.groups[r]then p[#p+1]={name=r,gid=q.groups[r].gid,members=q.groups[r].members}end end table.sort(p,function(t,u)if t.gid==u.gid then return t.name<u.name end return t.gid<u.gid end)return p end function a.groupsOf(t,s)local v=t.users[s]if not v then return nil end local q={}local p=a.groupByGid(t,v.gid)if p then q[#q+1]=p.name end local r={}for x,u in ipairs(a.groups(t))do if(not p or u.name~=p.name)and l(t.groups[u.name],s)then r[#r+1]=u.name end end for y,w in ipairs(r)do q[#q+1]=w end return q end function a.passwordStatus(r,p)local q=r.users[p]if not q then return nil end if q.locked then return"L"end if q.nopass then return"NP"end if not q.hash then return"L"end return"P"end local function e()if n().uid~=0 then return nil,"permission denied"end return true end local function i(q,p,r)if p=="uid"then for v,t in pairs(q.users)do if t.uid==r then return t.name end end else for u,s in pairs(q.groups)do if s.gid==r then return s.name end end end return nil end local function j(r,q)local p=1000 while i(r,q,p)do p=p+1 end return p end local function o(q,p)local r=q.groups[p]if not r then return nil end return r.gid end function a.setPassword(t,p,s,q)local r=t.users[p]if not r then return nil,"user '"..tostring(p).."' does not exist"end local x=n()if q==nil then local w,u=e();if not w then return nil,u end elseif x.uid~=0 then local v=a.byUid(t,x.uid)if not v or v.name~=p then return nil,"permission denied"end if not a.verify(t,p,s or"")then return nil,"incorrect old password"end end if q==nil then r.salt,r.hash,r.locked,r.nopass=nil,nil,false,true else r.salt=a.makeSalt()r.hash=a.hash(r.salt,q)r.locked,r.nopass=false,nil end return true end function a.setLocked(s,q,p)local u=s.users[q]if not u then return nil,"user '"..tostring(q).."' does not exist"end local t,r=e();if not t then return nil,r end u.locked=p and true or false return true end function a.addUser(r,q)local a1,z=e();if not a1 then return nil,z end local p=q.name if not h(p)then return nil,"invalid user name '"..tostring(p).."'"end if r.users[p]then return nil,"user '"..p.."' already exists"end local t=q.uid if t~=nil then if not g(t)then return nil,"invalid uid '"..tostring(t).."'"end local w=i(r,"uid",t)if w then return nil,"uid "..t.." is already in use by '"..w.."'"end else t=j(r,"uid")end for d1,v in ipairs(q.groups or{})do if not r.groups[v]then return nil,"group '"..v.."' does not exist"end end local s=q.gid if s~=nil then if not g(s)then return nil,"invalid gid '"..tostring(s).."'"end if not a.groupByGid(r,s)then return nil,"group with gid "..s.." does not exist"end elseif r.groups[p]then s=r.groups[p].gid else s=j(r,"gid")end if not q.gid and not r.groups[p]then r.groups[p]={name=p,gid=s,members=""}r.groupOrder[#r.groupOrder+1]=p end local y={name=p,uid=t,gid=s,full=q.full or"",home=q.home or("/home/"..p),shell=q.shell or"/bin/sh"}if q.password then y.salt=a.makeSalt()y.hash=a.hash(y.salt,q.password)else y.locked=true end r.users[p]=y r.userOrder[#r.userOrder+1]=p for c1,x in ipairs(q.groups or{})do local b1=r.groups[x]local u=c(b1)u[#u+1]=p b(b1,u)end return d(y)end function a.delUser(q,p)local x=q.users[p]if not x then return nil,"user '"..tostring(p).."' does not exist"end local w,t=e();if not w then return nil,t end local v=d(x)q.users[p]=nil for a1,c1 in ipairs(q.userOrder)do if c1==p then table.remove(q.userOrder,a1)break end end local y=q.groups[p]if y and y.gid==x.gid then q.groups[p]=nil for b1,d1 in ipairs(q.groupOrder)do if d1==p then table.remove(q.groupOrder,b1)break end end end for f1,u in pairs(q.groups)do local s=c(u)local r={}for e1,z in ipairs(s)do if z~=p then r[#r+1]=z end end if#r~=#s then b(u,r)end end return v end function a.modUser(s,q,p)local d1=s.users[q]if not d1 then return nil,"user '"..tostring(q).."' does not exist"end local m1,j1=e();if not m1 then return nil,j1 end if p.name~=nil and p.name~=q then local t=p.name if not h(t)then return nil,"invalid user name '"..tostring(t).."'"end if s.users[t]then return nil,"user '"..t.."' already exists"end s.users[t]=d1 s.users[q]=nil d1.name=t for s1,v1 in ipairs(s.userOrder)do if v1==q then s.userOrder[s1]=t break end end for w1,k1 in pairs(s.groups)do local y=c(k1)local h1=false for t1,u1 in ipairs(y)do if u1==q then y[t1]=t;h1=true end end if h1 then b(k1,y)end end q=t end if p.uid~=nil then if not g(p.uid)then return nil,"invalid uid '"..tostring(p.uid).."'"end local v=i(s,"uid",p.uid)if v and v~=q then return nil,"uid "..p.uid.." is already in use by '"..v.."'"end d1.uid=p.uid end if p.gid~=nil then if not g(p.gid)then return nil,"invalid gid '"..tostring(p.gid).."'"end if not a.groupByGid(s,p.gid)then return nil,"group with gid "..p.gid.." does not exist"end d1.gid=p.gid end if p.home~=nil then d1.home=p.home end if p.shell~=nil then d1.shell=p.shell end if p.full~=nil then d1.full=p.full end if p.locked~=nil then d1.locked=p.locked and true or false end local function r(e2)for f2,d2 in ipairs(e2 or{})do if not s.groups[d2]then return nil,"group '"..d2.."' does not exist"end end return true end local b1,w=r(p.groups);if not b1 then return nil,w end b1,w=r(p.groupsAdd);if not b1 then return nil,w end if p.groups then for c2,l1 in pairs(s.groups)do local c1,u=c(l1),{}for b2,r1 in ipairs(c1)do if r1~=q then u[#u+1]=r1 end end if#u~=#c1 then b(l1,u)end end for z1,g1 in ipairs(p.groups)do local o1=s.groups[g1]local z=c(o1);z[#z+1]=q;b(o1,z)end end for a2,e1 in ipairs(p.groupsAdd or{})do local n1=s.groups[e1]local a1=c(n1);a1[#a1+1]=q;b(n1,a1)end for x1,f1 in ipairs(p.groupsDel or{})do local p1=s.groups[f1]local i1,x=c(p1),{}for y1,q1 in ipairs(i1)do if q1~=q then x[#x+1]=q1 end end b(p1,x)end return d(d1)end function a.addGroup(s,p,q)local u,t=e();if not u then return nil,t end if not h(p)then return nil,"invalid group name '"..tostring(p).."'"end if s.groups[p]then return nil,"group '"..p.."' already exists"end if q~=nil then if not g(q)then return nil,"invalid gid '"..tostring(q).."'"end local r=i(s,"gid",q)if r then return nil,"gid "..q.." is already in use by '"..r.."'"end else q=j(s,"gid")end s.groups[p]={name=p,gid=q,members=""}s.groupOrder[#s.groupOrder+1]=p return{name=p,gid=q,members=""}end function a.delGroup(q,p)local s=q.groups[p]if not s then return nil,"group '"..tostring(p).."' does not exist"end local t,r=e();if not t then return nil,r end for x,u in pairs(q.users)do if u.gid==s.gid then return nil,"cannot remove the primary group of user '"..u.name.."'"end end q.groups[p]=nil for v,w in ipairs(q.groupOrder)do if w==p then table.remove(q.groupOrder,v)break end end return{name=p,gid=s.gid,members=s.members}end function a.save(t,w)local r,s,u=a.serialize(t)local function p(y,z,a1)if z==a1 then return true end local function x()local d1,c1=w.open(y,"w")if not d1 then return nil,y..": "..tostring(c1)end d1:write(z)local e1,b1=d1:close()if b1~=nil then return nil,y..": "..tostring(b1)end return true end if f and f.asRoot then return f.asRoot(x)end return x()end local v,q=p("/etc/passwd",r,t.raw.passwd);if not v then return nil,q end v,q=p("/etc/shadow",s,t.raw.shadow);if not v then return nil,q end v,q=p("/etc/group",u,t.raw.group);if not v then return nil,q end t.raw.passwd,t.raw.shadow,t.raw.group=r,s,u return true end function a.init(q)local function p(t)local r=q.open(t,"r")if not r then return""end local s=r.readAll();r.close()return s end return a.parse(p("/etc/passwd"),p("/etc/shadow"),p("/etc/group"))end function a.registerSyscalls(q,s)local r=m.syscalls()local function p(t)return function(...)local w,x=t(...)if w==nil then return nil,x end local v,u=a.save(q,s)if not v then return nil,u end return w,x end end r["user.verify"]=function(t,u)return a.verify(q,t,u)end r["user.get"]=function(t)return a.get(q,t)end r["user.list"]=function()return a.list(q)end r["user.groups"]=function()return a.groups(q)end r["user.groupsOf"]=function(t)return a.groupsOf(q,t)end r["user.passwordStatus"]=function(t)return a.passwordStatus(q,t)end r["user.byUid"]=function(t)return a.byUid(q,t)end r["user.groupByName"]=function(t)return a.groupByName(q,t)end r["user.groupByGid"]=function(t)return a.groupByGid(q,t)end r["user.setPassword"]=p(function(v,u,t)return a.setPassword(q,v,u,t)end)r["user.setLocked"]=p(function(u,t)return a.setLocked(q,u,t)end)r["user.addUser"]=p(function(t)return a.addUser(q,t)end)r["user.delUser"]=p(function(t)return a.delUser(q,t)end)r["user.modUser"]=p(function(u,t)return a.modUser(q,u,t)end)r["user.addGroup"]=p(function(t,u)return a.addGroup(q,t,u)end)r["user.delGroup"]=p(function(t)return a.delGroup(q,t)end)end return a end __chunks["kernel.version"]=function()local _ENV=setmetatable({require=__require},{__index=_G})return"0.0.3"end __chunks["kernel.vfs"]=function()local _ENV=setmetatable({require=__require},{__index=_G})local e={}local a={}local function b(i)if i==nil or i==""then return"/"end if i:sub(1,1)~="/"then i="/"..i end local j={}for k in i:gmatch("[^/]+")do if k==".."then if#j>0 then j[#j]=nil end elseif k~="."then j[#j+1]=k end end if#j==0 then return"/"end return"/"..table.concat(j,"/")end function e.mount(i,j,k)i=b(i)a[#a+1]={root=i,backend=j,meta=k}end function e.unmount(i)i=b(i)for j=#a,1,-1 do if a[j].root==i then table.remove(a,j)end end end local function h(i,j)if i=="/"then return true end return j==i or(j:sub(1,#i)==i and(j:sub(#i+1):sub(1,1)=="/"))end function e.list()local i={}for k,j in ipairs(a)do i[#i+1]={root=j.root,backend=j.backend,meta=j.meta}end return i end local function c(j)j=b(j)local i=nil for m,l in ipairs(a)do if h(l.root,j)and(not i or#l.root>#i.root)then i=l end end if not i then return nil,nil,"path not under any mount: "..j end local k if i.root=="/"then k=j else if j==i.root then k=""else k=j:sub(#i.root+1)end end return i.backend,k,nil end local f=40 local function d(q,m)local k={}for t in b(q):gmatch("[^/]+")do k[#k+1]=t end local i={}local o=0 while#k>0 do local n=table.remove(k,1)if n=="."then elseif n==".."then if#i>0 then i[#i]=nil end else local r=(#i==0)and"/"or("/"..table.concat(i,"/"))local p=(r=="/")and("/"..n)or(r.."/"..n)local j=nil if#k>0 or m then local u,w=c(p)if u and u.readlink then local v=u.attributes(w)if v and v.kind=="symlink"then local x,s=u.readlink(w)if not x then return nil,"cannot read symlink "..p..": "..tostring(s)end j=x end end end if j then o=o+1 if o>f then return nil,"too many levels of symbolic links: "..q end if j:sub(1,1)=="/"then i={}end local l={}for z in j:gmatch("[^/]+")do l[#l+1]=z end for y=#l,1,-1 do table.insert(k,1,l[y])end else i[#i+1]=n end end end if#i==0 then return"/"end return"/"..table.concat(i,"/")end function e.resolve(k)local i,j=d(k,true)if not i then return nil,nil,j end return c(i)end function e.resolveNoFollow(k)local i,j=d(k,false)if not i then return nil,nil,j end return c(i)end local function g(j)local k={}local function i(l)return l==k end k.read=function(l,m)if i(l)then return j.read(m)end return j.read(l)end k.readAll=function()return j.readAll()end k.readLine=function(l,m)if i(l)then return j.readLine(m)end return j.readLine(l)end k.write=function(l,...)if i(l)then return j.write(...)end return j.write(l,...)end k.writeLine=function(l,...)if i(l)then return j.writeLine(...)end return j.writeLine(l,...)end k.seek=function(l,...)if i(l)then return j.seek(...)end return j.seek(l,...)end k.flush=function()return j.flush()end k.close=function()return j.close()end k.isReadOnly=function()return j.isReadOnly()end k.raw=j return k end function e.real(j)j=j or""if j~=""and j~="/"and j:sub(-1)=="/"then j=j:sub(1,-2)end local function i(k)if k==""then return j end if j==""then return k end return j..k end return{kind="real",toReal=i,list=function(k)return fs.list(i(k))end,exists=function(k)return fs.exists(i(k))end,isDir=function(k)return fs.isDir(i(k))end,isFile=function(k)return fs.exists(i(k))and not fs.isDir(i(k))end,attributes=function(k)return fs.attributes(i(k))end,getSize=function(k)return fs.getSize(i(k))end,getDrive=function(k)return fs.getDrive(i(k))end,getFreeSpace=function(k)return fs.getFreeSpace(i(k))end,getCapacity=function(k)return fs.getCapacity(i(k))end,makeDir=function(k)return fs.makeDir(i(k))end,move=function(k,l)return fs.move(i(k),i(l))end,copy=function(k,l)return fs.copy(i(k),i(l))end,delete=function(k)return fs.delete(i(k))end,isReadOnly=function(k)return fs.isReadOnly(i(k))end,open=function(m,k)local n,l=fs.open(i(m),k)if not n then return nil,l end return g(n)end,}end function e.virtual(i)i.kind="virtual"return i end return e end __chunks["kernel.vfs_api"]=function()local _ENV=setmetatable({require=__require},{__index=_G})local l=require("kernel.vfs")local d={}local e={}function d.registerDevice(n,m)e[n]=m end function d.unregisterDevice(m)e[m]=nil end local function h(m)return m and m:gsub("^/+","")or""end local i=l.virtual({list=function(n)local m={}for o in pairs(e)do m[#m+1]=o end table.sort(m)return m end,exists=function(m)m=h(m)if m==""then return true end return e[m]~=nil end,isDir=function(m)return h(m)==""end,attributes=function(m)if h(m)==""then return{size=0,isDir=true,isReadOnly=true,kind="dir",name="dev",created=0,modified=0}end if e[h(m)]then return{size=0,isDir=false,isReadOnly=true,kind="device",name=h(m),created=0,modified=0}end return nil end,getSize=function(m)return 0 end,getDrive=function(m)return"vfs"end,getFreeSpace=function(m)return 0 end,getCapacity=function(m)return 0 end,isReadOnly=function(m)return true end,makeDir=function(m)error("read-only fs",2)end,move=function()error("read-only fs",2)end,copy=function()error("read-only fs",2)end,delete=function(m)error("read-only fs",2)end,open=function(o,n)local m=h(o)local p=e[m]if not p then return nil,"no such device: "..m end if not p.writable and n and n:find("w")then error("device is read-only: "..m,2)end if p.open then return p.open(n)end return nil,"device not openable: "..m end,})local b={}b.getName=fs.getName b.getDir=fs.getDir b.combine=fs.combine b.isDriveRoot=fs.isDriveRoot b.complete=fs.complete local function c(n)local m,p,o=l.resolve(n)if not m then error(tostring(o)or"bad path",2)end return m,p end local function a(n)local m,p,o=l.resolveNoFollow(n)if not m then error(tostring(o)or"bad path",2)end return m,p end function b.list(m)local n,o=c(m);return n.list(o)end function b.exists(m)local n,o=c(m);return n.exists(o)end function b.isDir(m)local n,o=c(m);return n.isDir(o)end function b.isReadOnly(m)local n,o=c(m);return n.isReadOnly(o)end function b.attributes(m)local n,o=c(m);return n.attributes(o)end function b.lstat(m)local n,o=a(m);return n.attributes(o)end function b.getSize(m)local n,o=c(m);return n.getSize(o)end function b.getDrive(m)local n,o=c(m);return n.getDrive(o)end function b.getFreeSpace(m)local n,o=c(m);return n.getFreeSpace(o)end function b.getCapacity(m)local n,o=c(m);return n.getCapacity(o)end function b.makeDir(m)local n,o=a(m);return n.makeDir(o)end function b.move(p,q)local m,n=a(p)local r,o=a(q)return m.move(n,o)end function b.copy(p,q)local m,n=c(p);local r,o=c(q);return m.copy(n,o)end function b.delete(m)local n,o=a(m);return n.delete(o)end function b.open(n,m)local o,p=c(n);return o.open(p,m)end function b.chmod(n,m)local o,p=c(n);if o.chmod then return o.chmod(p,m)end return nil,"chmod not supported"end function b.chown(m,o,n)local p,q=c(m);if p.chown then return p.chown(q,o,n)end return nil,"chown not supported"end function b.lchown(m,o,n)local p,q=a(m)if not p.chown then return nil,"chown not supported"end return p.chown(q,o,n)end function b.canExecute(m)local n,o=c(m);if n.canExecute then return n.canExecute(o)end return true end function b.symlink(n,m)local o,p=a(m)if not o.symlink then return nil,"symbolic links are not supported on this filesystem"end return o.symlink(n,p)end function b.readlink(m)local n,o=a(m)if not n.readlink then return nil,"not a symbolic link"end return n.readlink(o)end function b.link(n,m)local o,r=a(n)local p,q=a(m)if o~=p then return nil,"cross-filesystem hard link is not allowed"end if not o.link then return nil,"hard links are not supported on this filesystem"end return o.link(r,q)end function b.mkfifo(n,m)local o,p=a(n)if not o.mkfifo then return nil,"named pipes are not supported on this filesystem"end return o.mkfifo(p,m)end function b.isFifo(m)local o,p=a(m)local n=o.attributes(p)return n~=nil and n.kind=="fifo"end function b.isFile(m)local n,o=c(m)if n.isFile then return n.isFile(o)end return n.exists(o)and not n.isDir(o)end function b.find(o)local m={}local function n(t)local r,s=c(t)if r.exists(s)and r.isDir(s)then for v,u in ipairs(r.list(s))do local q=b.combine(t,u)n(q)end elseif r.exists(s)then m[#m+1]=t end end n(o)local p=0 return function()p=p+1;return m[p]end end local g=nil local f={}function f.open(n,m)return b.open(n,m or"r")end function f.type(m)if type(m)=="table"and getmetatable(m)and getmetatable(m).__ioType then return getmetatable(m).__ioType end if type(m)=="userdata"then return"file"end return nil end function f.close(m)if m and m.close then return m:close()end end function f.lines(m,...)if m then local n=b.open(m,"r")if not n then return function()return nil end end return n.lines and n.lines()or function()return n.readLine()end end return function()return nil end end local function k(m)return{open=f.open,type=f.type,close=f.close,lines=f.lines,write=function(...)local n={}for o=1,select("#",...)do n[o]=tostring(select(o,...))end if m.output then return m.output:write(table.concat(n))end return write(table.concat(n))end,read=function(...)if m.input then return m.input:read(...)end return read(...)end,flush=function()if m.output and m.output.flush then return m.output:flush()end end,stdout=function()return m.output end,stderr=function()return m.output end,stdin=function()return m.input end,}end function d.setStdio(n,m)g={input=n,output=m}end function d.getStdio()return g end function d.mountDev()l.mount("/dev",i,{device="devtmpfs",fstype="devtmpfs"})end local function j()return{read=function()return nil end,readLine=function()return nil end,write=function(n,m)return#tostring(m or"")end,flush=function()return true end,close=function()return true end,}end d.registerDevice("null",{writable=true,open=function()return j()end,})d.fs=b function d.devices()local m={}for n in pairs(e)do m[#m+1]=n end return m end function d.installForEnv(n)n.fs=b local m={input=nil,output=nil}n.__stdio=m n.io=k(m)end return d end __chunks["kernel.init_src"]=function()return[=[-- init bundle: 前 N-1 个为内部模块, 最后一个为顶层主程序
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
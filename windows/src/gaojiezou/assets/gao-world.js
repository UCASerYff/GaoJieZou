(() => {
  "use strict";
  const DEG = Math.PI / 180;
  const TAU = Math.PI * 2;
  const scenes = new Map();
  const clamp = (value, min, max) => Math.max(min, Math.min(max, value));
  const dot = (a, b) => a[0]*b[0] + a[1]*b[1] + a[2]*b[2];
  const origin = [0,0,0];

  function color(value = "#ffffff") {
    if (Array.isArray(value)) return [...value.slice(0,3), value[3] ?? 1];
    if (!/^#[a-f0-9]{6}$/i.test(value)) return [1,1,1,1];
    return [1,3,5].map(index => parseInt(value.slice(index,index+2),16)/255).concat(1);
  }

  function matrix(right,up,forward,position) {
    return [right[0],right[1],right[2],0,up[0],up[1],up[2],0,
      forward[0],forward[1],forward[2],0,position[0],position[1],position[2],1];
  }
  const identity = matrix([1,0,0],[0,1,0],[0,0,1],origin);
  function multiply(left,right) {
    const result = new Float32Array(16);
    for (let column=0;column<16;column+=4) {
      for (let row=0;row<4;row++) {
        result[column+row] = left[row]*right[column] + left[row+4]*right[column+1] +
          left[row+8]*right[column+2] + left[row+12]*right[column+3];
      }
    }
    return result;
  }
  function transform(node,parent) {
    const { x,y,z,rx,ry,rz,scale,scaleX,scaleY,scaleZ } = node;
    if (!(x || y || z || rx || ry || rz || scale !== 1 || scaleX !== 1 || scaleY !== 1 || scaleZ !== 1)) return parent;
    const sx=scale*scaleX,sy=scale*scaleY,sz=scale*scaleZ;
    const a=Math.cos(rx), b=Math.sin(rx), c=Math.cos(ry), d=Math.sin(ry), e=Math.cos(rz), f=Math.sin(rz);
    // Scene-space yaw and pitch carry the local roll.
    return multiply(parent,matrix(
      [(c*e+d*b*f)*sx,a*f*sx,(-d*e+c*b*f)*sx],
      [(-c*f+d*b*e)*sy,a*e*sy,(d*f+c*b*e)*sy],
      [d*a*sz,-b*sz,c*a*sz],[x,y,z]));
  }
  const center = m => [m[12],m[13],m[14]];
  function position(point,m) {
    return [point[0]*m[0]+point[1]*m[4]+point[2]*m[8]+m[12],
      point[0]*m[1]+point[1]*m[5]+point[2]*m[9]+m[13],
      point[0]*m[2]+point[1]*m[6]+point[2]*m[10]+m[14]];
  }

  class Vertices {
    constructor() {
      this.data = [];
      this.corners = [[Infinity,Infinity,Infinity],[-Infinity,-Infinity,-Infinity]];
    }
    put(point, normal, uv) {
      this.data.push(...point,...normal,...uv);
      for (let d=0;d<3;d++) {
        this.corners[0][d]=Math.min(this.corners[0][d],point[d]);
        this.corners[1][d]=Math.max(this.corners[1][d],point[d]);
      }
    }
    face(points,normal,uv=[[0,1],[1,1],[1,0],[0,0]]) {
      for(const i of [0,1,2,0,2,3]) this.put(points[i],normal,uv[i]);
    }
  }
  function boxMesh({w,h,d}) {
    const out=new Vertices(), x=w/2,y=h/2,z=d/2;
    out.face([[-x,-y,z],[x,-y,z],[x,y,z],[-x,y,z]],[0,0,1]);
    out.face([[x,-y,-z],[-x,-y,-z],[-x,y,-z],[x,y,-z]],[0,0,-1]);
    out.face([[-x,-y,-z],[-x,-y,z],[-x,y,z],[-x,y,-z]],[-1,0,0]);
    out.face([[x,-y,z],[x,-y,-z],[x,y,-z],[x,y,z]],[1,0,0]);
    out.face([[-x,y,z],[x,y,z],[x,y,-z],[-x,y,-z]],[0,1,0]);
    out.face([[-x,-y,-z],[x,-y,-z],[x,-y,z],[-x,-y,z]],[0,-1,0]);
    return out;
  }
  function planeMesh({w,h}) {
    const out=new Vertices(), x=w/2,y=h/2;
    out.face([[-x,-y,0],[x,-y,0],[x,y,0],[-x,y,0]],[0,0,1]);
    return out;
  }
  function cylinderMesh({r,top=r,h,segments=20}) {
    const out=new Vertices(), y=h/2;
    for(let i=0;i<segments;i++){
      const first=TAU*i/segments, second=TAU*(i+1)/segments;
      const points=[[Math.cos(first),Math.sin(first)],[Math.cos(second),Math.sin(second)]];
      const normal=point=>[point[0],(r-top)/h,point[1]];
      for(const [index,atTop] of [[0,false],[1,false],[1,true],[0,false],[1,true],[0,true]]) {
        const [px,pz]=points[index],radius=atTop?top:r;
        out.put([px*radius,atTop?y:-y,pz*radius],normal(points[index]),[(i+index)/segments,atTop?0:1]);
      }
      for(const [sign, radius] of [[-1,r],[1,top]]) if(radius>0) {
        out.put([0,y*sign,0],[0,sign,0],[.5,.5]);
        for(const [px,pz] of points) out.put([px*radius,y*sign,pz*radius],[0,sign,0],[.5+px/2,.5+pz/2]);
      }
    }
    return out;
  }
  function sphereMesh({r=1,sx=1,sy=1,sz=1,segments=14}) {
    const out=new Vertices(), rows=segments/2;
    for(let y=0;y<rows;y++) for(let x=0;x<segments;x++) {
      for(const [ix,iy] of [[0,0],[1,0],[1,1],[0,0],[1,1],[0,1]]) {
        const u=(x+ix)/segments,v=(y+iy)/rows;
        const a=TAU*u,b=Math.PI*v;
        const n=[Math.cos(a)*Math.sin(b),Math.cos(b),Math.sin(a)*Math.sin(b)];
        out.put([n[0]*r*sx,n[1]*r*sy,n[2]*r*sz],[n[0]/sx,n[1]/sy,n[2]/sz],[u,v]);
      }
    }
    return out;
  }
  function prismMesh({points,h}) {
    const out=new Vertices(), y=h/2;
    const width = Math.max(1,...points.map(p=>Math.abs(p[0])));
    const depth = Math.max(1,...points.map(p=>Math.abs(p[1])));
    const area=points.reduce((sum,p,i)=>{
      const q=points[(i+1)%points.length];
      return sum+p[0]*q[1]-q[0]*p[1];
    },0);
    for(let i=0;i<points.length;i++) {
      const p=points[i],q=points[(i+1)%points.length];
      const normal=[(q[1]-p[1])*Math.sign(area),0,(p[0]-q[0])*Math.sign(area)];
      out.face([[p[0],-y,p[1]],[q[0],-y,q[1]],[q[0],y,q[1]],[p[0],y,p[1]]],normal);
      for (const sign of [-1,1]) {
        out.put([0,sign*y,0],[0,sign,0],[.5,.5]);
        for(const [x,z] of [p,q]) out.put([x,sign*y,z],[0,sign,0],[.5+x/width/2,.5+z/depth/2]);
      }
    }
    return out;
  }
  function ringMesh({r,width,segments=36}) {
    const out=new Vertices();
    for(let i=0;i<segments;i++) {
      const a=TAU*i/segments,b=TAU*(i+1)/segments;
      const point=(angle,radius)=>[Math.cos(angle)*radius,0,Math.sin(angle)*radius];
      out.face([point(a,r-width/2),point(b,r-width/2),point(b,r+width/2),point(a,r+width/2)],[0,1,0]);
    }
    return out;
  }

  const builders={box:boxMesh,plane:planeMesh,cylinder:cylinderMesh,sphere:sphereMesh,prism:prismMesh,ring:ringMesh};
  const meshKeys={
    box:["w","h","d"],plane:["w","h"],cylinder:["r","top","h","segments"],sphere:["r","sx","sy","sz","segments"],
    prism:["points","h"],ring:["r","width","segments"]
  };
  class Node {
    constructor(scene,params) {
      this.scene=scene;
      this.children=[];
      Object.assign(this,{x:0,y:0,z:0,rx:0,ry:0,rz:0,scale:1,scaleX:1,scaleY:1,scaleZ:1},params);
      if (this.id) scene.objects.set(this.id,this);
      if (this.animate) scene.isAnimated=true;
    }
    group(params={}) {
      const node=new Node(this.scene,params);
      this.children.push(node);
      return node;
    }
    primitive(kind,options) {
      const node=this.group(options);
      node.mesh=this.scene.mesh(kind,options);
      node.material={
        color:color(options.color),texture:options.texture,uv:options.uv || [0,0,1,1], repeat:options.repeat || [1,1],
        lit:options.lit ?? !options.billboard,cutout:!!options.cutout,shine:options.shine || 0
      };
      return node;
    }
    box(options) {return this.primitive("box",options);}
    plane(options) {return this.primitive("plane",options);}
    cylinder(options) {return this.primitive("cylinder",options);}
    sphere(options) {return this.primitive("sphere",options);}
    prism(options) {return this.primitive("prism",options);}
    ring(options) {return this.primitive("ring",options);}
    beam({from,to,r,color: tint,shine}) {
      const v=to.map((part,i)=>part-from[i]),h=Math.hypot(...v);
      if (!h) return null;
      return this.cylinder({x:(from[0]+to[0])/2,y:(from[1]+to[1])/2,z:(from[2]+to[2])/2,
        r,h,rx:Math.atan2(v[2],v[1]),rz:-Math.asin(v[0]/h),color:tint,shine,segments:10});
    }
  }

  const vertex = 'attribute vec3 aPosition,aNormal;attribute vec2 aUV;uniform mat4 uModel,uView;varying vec3 vNormal;varying vec2 vUV;void main(){gl_Position=uView*uModel*vec4(aPosition,1.0);vNormal=mat3(uModel)*aNormal;vUV=aUV;}';
  const fragment = 'precision mediump float;varying vec3 vNormal;varying vec2 vUV;uniform vec4 uColor,uCrop;uniform vec2 uRepeat;uniform float uHasTexture,uLighting,uShine,uFlip,uCutout;uniform sampler2D uTexture;void main(){vec2 uv=vec2(mix(vUV.x,1.0-vUV.x,uFlip),vUV.y);if(uRepeat.x!=1.0||uRepeat.y!=1.0)uv=fract(uv*uRepeat);vec4 color=uColor;if(uHasTexture>0.5)color*=texture2D(uTexture,uCrop.xy+clamp(uv,0.002,0.998)*uCrop.zw);if(color.a<0.015||(uCutout>0.5&&color.a<0.42))discard;vec3 n=normalize(vNormal);vec3 l=normalize(vec3(-0.48,0.88,0.54));float diffuse=max(0.0,dot(l,n));float gloss=pow(max(0.0,dot(normalize(l+vec3(0.0,0.45,0.92)),n)),16.0);color.rgb*=mix(vec3(1.0),vec3(0.58,0.62,0.67)+diffuse*vec3(0.46,0.40,0.33),uLighting);color.rgb+=uShine*gloss*0.19;gl_FragColor=color;}';
  function compile(gl,type,source) {
    const shader=gl.createShader(type);
    gl.shaderSource(shader,source);
    gl.compileShader(shader);
    if (!gl.getShaderParameter(shader,gl.COMPILE_STATUS)) {
      const error=gl.getShaderInfoLog(shader);
      gl.deleteShader(shader);
      throw new Error(error);
    }
    return shader;
  }
  function createProgram(gl) {
    const program=gl.createProgram();
    const shaders=[compile(gl,gl.VERTEX_SHADER,vertex),compile(gl,gl.FRAGMENT_SHADER,fragment)];
    for(const shader of shaders) gl.attachShader(program,shader);
    gl.linkProgram(program);
    for(const shader of shaders) gl.deleteShader(shader);
    if (!gl.getProgramParameter(program,gl.LINK_STATUS)) throw new Error(gl.getProgramInfoLog(program));
    return program;
  }

  function makeCanvasLabel(text,detail,progress,colorValue) {
    const canvas=document.createElement("canvas");
    canvas.width=384; canvas.height=detail || progress != null ? 130 : 72;
    const ctx=canvas.getContext("2d");
    ctx.fillStyle=colorValue || "rgba(18,40,32,.90)";
    ctx.beginPath();ctx.roundRect(0,0,canvas.width,canvas.height,22);ctx.fill();
    ctx.textAlign="center";ctx.textBaseline="middle";ctx.fillStyle="#fff";
    ctx.font="600 43px Segoe UI, Microsoft YaHei UI, sans-serif";ctx.fillText(text,192,detail ? 34 : 36,348);
    if (detail) {
      ctx.font="500 30px Segoe UI, Microsoft YaHei UI, sans-serif";ctx.fillText(detail,192,81,350);
    }
    if (progress != null) {
      ctx.fillStyle="#ffffff44";ctx.fillRect(30,112,324,7);
      ctx.fillStyle=progress>=1?"#f1cf71":"#73d3a2";ctx.fillRect(30,112,324*clamp(progress,0,1),7);
    }
    return canvas;
  }

  class World {
    constructor(host,canvas,gl,options) {
      this.host=host;this.canvas=canvas;this.gl=gl;this.options=options;this.objects=new Map();
      this.assets=new Map();this.meshes=new Map();this.root=new Node(this,{});
      this.yaw=options.yaw || 0;this.zoom=options.zoom || 8.5;
      this.camera={target:origin,pitch:Math.atan2(13,17),minimumZoom:3,maximumZoom:25,...options.camera};
      this.selected=options.selectedID ?? null;
      this.animation=0;this.lastDraw=-Infinity;this.start=performance.now();this.active=true;
      this.isAnimated=false;this.drawList=[];this.hits=new Map();
      this.program=createProgram(gl);
      this.attributes=Object.fromEntries(["aPosition","aNormal","aUV"].map(name=>[name,gl.getAttribLocation(this.program,name)]));
      this.uniforms=Object.fromEntries(["uModel","uView","uColor","uCrop","uRepeat","uHasTexture","uLighting","uShine","uFlip","uCutout","uTexture"].map(name=>[name,gl.getUniformLocation(this.program,name)]));
      this.signal=new AbortController();
      gl.enable(gl.DEPTH_TEST);
      gl.enable(gl.BLEND);
      gl.blendFuncSeparate(gl.SRC_ALPHA,gl.ONE_MINUS_SRC_ALPHA,gl.ONE,gl.ONE_MINUS_SRC_ALPHA);
    }
    group(options) {return this.root.group(options);}
    label(group,{text,y=1,x=0,z=0,detail,progress,color: tint,w=1.7,onlySelected=false}){
      const texture=makeCanvasLabel(text,detail,progress,tint);
      return group.plane({x,y,z,w,h:w*texture.height/texture.width,texture,billboard:true,onlySelected,lit:false});
    }
    mesh(kind,options) {
      const key=kind+":"+JSON.stringify(meshKeys[kind].map(name=>options[name]));
      if(this.meshes.has(key)) return this.meshes.get(key);
      const geometry=builders[kind](options);
      const buffer=this.gl.createBuffer();
      this.gl.bindBuffer(this.gl.ARRAY_BUFFER,buffer);
      this.gl.bufferData(this.gl.ARRAY_BUFFER,new Float32Array(geometry.data),this.gl.STATIC_DRAW);
      const mesh={buffer,length:geometry.data.length/8,corners:geometry.corners,key};
      this.meshes.set(key,mesh);
      return mesh;
    }
    texture(source) {
      if (!source) return null;
      if(this.assets.has(source)) return this.assets.get(source).texture;
      const gl=this.gl, asset={texture:null};
      this.assets.set(source,asset);
      const upload=image=>{
        if (!this.active) return;
        const texture=gl.createTexture();
        gl.bindTexture(gl.TEXTURE_2D,texture);
        gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_WRAP_S,gl.CLAMP_TO_EDGE);
        gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_WRAP_T,gl.CLAMP_TO_EDGE);
        gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_MIN_FILTER,gl.LINEAR);
        gl.texParameteri(gl.TEXTURE_2D,gl.TEXTURE_MAG_FILTER,gl.LINEAR);
        gl.texImage2D(gl.TEXTURE_2D,0,gl.RGBA,gl.RGBA,gl.UNSIGNED_BYTE,image);
        asset.texture=texture;
        this.request();
      };
      if(typeof source==="string") {
        const image=new Image();
        image.onload=()=>upload(image);
        image.src=source;
      } else upload(source);
      return asset.texture;
    }
    connect() {
      const signal=this.signal.signal,c=this.canvas;
      c.addEventListener("pointerdown",e=>this.pointerDown(e),{signal});
      c.addEventListener("pointermove",e=>this.pointerMove(e),{signal});
      c.addEventListener("pointerup",e=>this.pointerUp(e),{signal});
      c.addEventListener("pointercancel",()=>this.cancelDrag(),{signal});
      c.addEventListener("lostpointercapture",()=>this.cancelDrag(),{signal});
      c.addEventListener("wheel",e=>{
        e.preventDefault();
        this.setZoom(this.zoom*Math.exp(clamp(e.deltaY,-100,100)*.0025));
      },{passive:false,signal});
      c.addEventListener("keydown",e=>this.key(e),{signal});
      c.addEventListener("webglcontextlost",e=>{e.preventDefault();this.destroy();this.options.onFallback?.();},{signal});
      document.addEventListener("visibilitychange",()=>this.request(),{signal});
      this.observer=new ResizeObserver(()=>this.request());
      this.observer.observe(this.host);
      this.visible=true;
      this.visibility=new IntersectionObserver(entries=>{this.visible=entries.at(-1)?.isIntersecting ?? true;this.request();});
      this.visibility.observe(this.host);
      this.request();
    }
    getCamera(){return {yaw:this.yaw,zoom:this.zoom};}
    setZoom(value){
      if(!Number.isFinite(value)) return;
      this.zoom=clamp(value,this.camera.minimumZoom,this.camera.maximumZoom);
      this.options.onCamera?.(this.getCamera());
      this.request();
    }
    setYaw(value){
      if (!Number.isFinite(value)) return;
      this.yaw=((value%360)+360)%360;
      this.options.onCamera?.(this.getCamera());
      this.request();
    }
    setSelected(id){
      const next=this.objects.has(id)?id:null;
      if (next===this.selected) return;
      this.selected=next;
      this.canvas.dataset.worldSelection=next ?? "";
      this.request();
    }
    key(event) {
      if (["ArrowLeft","ArrowRight","ArrowUp","ArrowDown","-","+","="].includes(event.key)) {
        event.preventDefault();
        if(event.key==="ArrowLeft" || event.key==="ArrowRight"){
          if(this.options.rotate !== false) this.setYaw(this.yaw+(event.key==="ArrowLeft"?-6:6));
        } else this.setZoom(this.zoom+(["-","ArrowDown"].includes(event.key)?.5:-.5));
      } else if (["PageUp","PageDown"].includes(event.key)){
        event.preventDefault();
        const ids=[...this.objects.keys()], current=ids.indexOf(this.selected);
        if (ids.length){
          const index=(current+(event.key==="PageDown"?1:ids.length-1)+ids.length)%ids.length;
          this.setSelected(ids[index]);
        }
      } else if (event.key==="Enter" || event.key===" "){
        event.preventDefault();
        if (this.selected) this.options.onSelect?.(this.selected);
      }
    }
    basis() {
      const a=this.yaw*DEG,p=this.camera.pitch;
      this.right=[Math.cos(a),0,-Math.sin(a)];
      this.up=[-Math.sin(a)*Math.sin(p),Math.cos(p),-Math.cos(a)*Math.sin(p)];
      this.forward=[-Math.sin(a)*Math.cos(p),-Math.sin(p),-Math.cos(a)*Math.cos(p)];
      const target=this.camera.target;
      const aspect=this.canvas.width/this.canvas.height;
      const x=this.zoom*aspect,y=this.zoom,d=50;
      this.aspect=aspect;
      this.projection=new Float32Array([
        this.right[0]/x,this.up[0]/y,this.forward[0]/d,0,
        this.right[1]/x,this.up[1]/y,this.forward[1]/d,0,
        this.right[2]/x,this.up[2]/y,this.forward[2]/d,0,
        -dot(this.right,target)/x,-dot(this.up,target)/y,-dot(this.forward,target)/d,1
      ]);
    }
    loc(event) {
      const rect=this.canvas.getBoundingClientRect();
      return [2*(event.clientX-rect.left)/rect.width-1,1-2*(event.clientY-rect.top)/rect.height];
    }
    ground([x,y]){
      if(!this.forward || Math.abs(this.forward[1])<.001) return null;
      const pos=this.camera.target.map((part,i)=>part+x*this.zoom*this.aspect*this.right[i]+y*this.zoom*this.up[i]);
      const d=-pos[1]/this.forward[1];
      return [pos[0]+d*this.forward[0],pos[2]+d*this.forward[2]];
    }
    pick([x,y]){
      let candidate=null,nearest=Infinity;
      const padX=.012,padY=.016;
      for(const [id,box] of this.hits){
        if(x<box[0]-padX || y<box[1]-padY || x>box[2]+padX || y>box[3]+padY || box[4]>=nearest) continue;
        candidate=id;nearest=box[4];
      }
      return candidate;
    }
    pointerDown(event){
      if (event.button!==0 || this.drag) return;
      const point=this.loc(event),id=this.pick(point),node=this.objects.get(id);
      this.drag={pointer:event.pointerId,x:event.clientX,y:event.clientY,yaw:this.yaw,id,node,ground:this.ground(point),
        old:node?[node.x,node.z]:null,moved:false};
      this.canvas.setPointerCapture(event.pointerId);
      this.setSelected(id);
    }
    pointerMove(event){
      const drag=this.drag;
      if (!drag || drag.pointer!==event.pointerId) return;
      const dx=event.clientX-drag.x,dy=event.clientY-drag.y;
      if (!drag.moved && Math.hypot(dx,dy)<4) return;
      drag.moved=true;
      if (drag.node?.movable && drag.ground){
        const now=this.ground(this.loc(event)),limit=this.options.dragBoundary || 11;
        if(!now) return;
        drag.node.x=clamp(drag.old[0]+now[0]-drag.ground[0],-limit,limit);
        drag.node.z=clamp(drag.old[1]+now[1]-drag.ground[1],-limit,limit);
        this.request();
      } else if (!drag.node && this.options.rotate!==false) this.setYaw(drag.yaw+dx*.28);
    }
    async pointerUp(event){
      const drag=this.drag;
      if (!drag || drag.pointer!==event.pointerId) return;
      this.drag=null;
      if (!drag.moved) {
        this.options.onSelect?.(drag.id);
      } else if (drag.node?.movable) {
        try {
          const accepted=await this.options.onMove?.(drag.id,drag.node.x,drag.node.z);
          if(!accepted) [drag.node.x,drag.node.z]=drag.old;
        } catch {
          [drag.node.x,drag.node.z]=drag.old;
        }
        this.request();
      }
    }
    cancelDrag(){
      if (this.drag?.node?.movable) [this.drag.node.x,this.drag.node.z]=this.drag.old;
      this.drag=null;
      this.request();
    }
    addBounds(id,mesh,world){
      if (!this.hits.has(id)) this.hits.set(id,[Infinity,Infinity,-Infinity,-Infinity,Infinity]);
      const hit=this.hits.get(id);
      const [a,b]=mesh.corners;
      const m=multiply(this.projection,world);
      for (const x of [a[0],b[0]]) for (const y of [a[1],b[1]]) for(const z of [a[2],b[2]]) {
        const pt=position([x,y,z],m);
        hit[0]=Math.min(hit[0],pt[0]);hit[1]=Math.min(hit[1],pt[1]);hit[2]=Math.max(hit[2],pt[0]);
        hit[3]=Math.max(hit[3],pt[1]);hit[4]=Math.min(hit[4],pt[2]);
      }
    }
    walk(node,parent,id,time) {
      if (node.hidden) return;
      if (node.animate && this.drag?.node!==node) node.animate(node,time);
      if (node.id) id=node.id;
      if (node.onlySelected && id!==this.selected) return;
      let world=transform(node,parent);
      if (node.billboard){
        const scale=Math.hypot(world[0],world[1],world[2]);
        const up=node.billboard==="y"?[0,1,0]:this.up;
        const normal=node.billboard==="y"?[-this.forward[0],0,-this.forward[2]]:this.forward.map(value=>-value);
        world=matrix(this.right.map(value=>value*scale),up.map(value=>value*scale),normal.map(value=>value*scale),center(world));
      }
      if (node.mesh) {
        const textured=this.texture(node.material.texture);
        const pending=node.material.texture && !textured;
        if (id && !node.onlySelected && !node.ignorePick) this.addBounds(id,node.mesh,world);
        if (!(pending && node.billboard)) {
          this.drawList.push({node,world,textured,depth:dot(center(world),this.forward)});
        }
      }
      for (const child of node.children) this.walk(child,world,id,time);
      if(node.id===this.selected && this.selectionRing && this.options.selectionRing!==false){
        const selection=transform(this.selectionRing,world);
        this.drawList.push({node:this.selectionRing,world:selection,textured:null,depth:dot(center(selection),this.forward)});
      }
    }
    request(){
      if(this.active && !this.animation && !document.hidden && this.visible) this.animation=requestAnimationFrame(now=>this.draw(now));
    }
    draw(now){
      this.animation=0;
      if(!this.active || !this.host.isConnected) {this.destroy();return;}
      if(this.isAnimated && now-this.lastDraw<30) {this.request();return;}
      const gl=this.gl, c=this.canvas, bounds=c.getBoundingClientRect(), dpr=Math.min(window.devicePixelRatio || 1,2);
      const width=Math.min(3000,Math.round(bounds.width*dpr)),height=Math.min(2600,Math.round(bounds.height*dpr));
      if(width<2 || height<2) return;
      if (c.width!==width || c.height!==height){c.width=width;c.height=height;}
      this.lastDraw=now;
      this.basis();
      gl.viewport(0,0,width,height);
      gl.clearColor(0,0,0,0);
      gl.clear(gl.COLOR_BUFFER_BIT|gl.DEPTH_BUFFER_BIT);
      this.drawList.length=0;this.hits.clear();
      const reduceMotion=matchMedia("(prefers-reduced-motion: reduce)").matches;
      const seconds=reduceMotion?0:(now-this.start)/1000;
      this.walk(this.root,identity,null,seconds);
      gl.useProgram(this.program);
      gl.uniformMatrix4fv(this.uniforms.uView,false,this.projection);
      const opaque=[],translucent=[];
      for (const entry of this.drawList) (entry.node.material.color[3]<1 || entry.node.billboard && !entry.node.material.cutout ? translucent : opaque).push(entry);
      translucent.sort((a,b)=>b.depth-a.depth);
      gl.depthMask(true);
      this.paint(opaque);
      gl.depthMask(false);
      this.paint(translucent);
      gl.depthMask(true);
      c.dataset.worldReady="true";
      c.dataset.worldObjects=String(this.objects.size);
      if (this.isAnimated && !reduceMotion) this.request();
    }
    paint(entries){
      const gl=this.gl, u=this.uniforms, a=this.attributes;
      let activeBuffer=null,currentTexture;
      for (const {node,world,textured} of entries){
        const mesh=node.mesh,m=node.material;
        if(activeBuffer!==mesh.buffer) {
          activeBuffer=mesh.buffer;
          gl.bindBuffer(gl.ARRAY_BUFFER,activeBuffer);
          gl.vertexAttribPointer(a.aPosition,3,gl.FLOAT,false,32,0);
          gl.vertexAttribPointer(a.aNormal,3,gl.FLOAT,false,32,12);
          gl.vertexAttribPointer(a.aUV,2,gl.FLOAT,false,32,24);
          for(const offset of Object.values(a)) gl.enableVertexAttribArray(offset);
        }
        if (currentTexture!==textured){currentTexture=textured;gl.bindTexture(gl.TEXTURE_2D,textured);}
        gl.uniformMatrix4fv(u.uModel,false,world);
        gl.uniform4fv(u.uColor,m.color);gl.uniform4fv(u.uCrop,m.uv);gl.uniform2fv(u.uRepeat,m.repeat);
        gl.uniform1f(u.uHasTexture,textured?1:0);gl.uniform1f(u.uLighting,m.lit?1:0);
        gl.uniform1f(u.uShine,m.shine);gl.uniform1f(u.uFlip,node.flipX?1:0);gl.uniform1f(u.uCutout,m.cutout?1:0);
        gl.drawArrays(gl.TRIANGLES,0,mesh.length);
      }
    }
    destroy(){
      if (!this.active) return;
      this.active=false;
      cancelAnimationFrame(this.animation);
      this.signal.abort();
      this.observer?.disconnect();
      this.visibility?.disconnect();
      const gl=this.gl;
      for (const asset of this.assets.values()) if(asset.texture) gl.deleteTexture(asset.texture);
      for (const mesh of this.meshes.values()) gl.deleteBuffer(mesh.buffer);
      gl.deleteProgram(this.program);
      gl.getExtension("WEBGL_lose_context")?.loseContext();
      this.canvas.remove();
      this.host.classList.remove("has-webgl-world");
      scenes.delete(this.host);
    }
  }

  function mount(host,options){
    if(!host) return null;
    if(scenes.has(host)) scenes.get(host).destroy();
    const canvas=document.createElement("canvas");
    canvas.className="gao-world-canvas";
    canvas.tabIndex=0;
    canvas.dataset.worldMode=options.mode;
    canvas.setAttribute("aria-label",options.label || options.mode);
    const gl=canvas.getContext("webgl",{alpha:true,antialias:true,premultipliedAlpha:false,powerPreference:"low-power"});
    if(!gl) return null;
    let world;
    try {
      world=new World(host,canvas,gl,options);
      options.build(world,options.items || []);
      world.selectionRing=world.root.ring({r:options.selectionRadius || .95,width:.065,y:.08,color:"#efc64f",lit:false});
      world.root.children.pop();
      host.classList.add("has-webgl-world");
      host.prepend(canvas);
      world.connect();
      scenes.set(host,world);
      return world;
    } catch {
      world?.destroy();
      if(!world) gl.getExtension("WEBGL_lose_context")?.loseContext();
      return null;
    }
  }
  function releaseWithin(container){
    for (const [host,world] of scenes) if(container.contains(host) || !host.isConnected) world.destroy();
  }
  window.GaoWorld={mount,releaseWithin,TAU,DEG};
})();

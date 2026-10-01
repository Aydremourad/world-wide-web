(function(){
function isLocal(h){
 if(!h){return false;}
 if(h.charAt(0)=='#'){return false;}
 if(h.indexOf('javascript:')==0 || h.indexOf('mailto:')==0 || h.indexOf('tel:')==0){return false;}
 if(h.indexOf('://')==-1){return true;}
 return h.indexOf(location.protocol+'//'+location.host)==0;
}
function keepInside(e){
 if(!window.navigator.standalone){return;}
 e=e||window.event;
 var t=e.target||e.srcElement;
 while(t && t.tagName && t.tagName.toLowerCase()!='a'){t=t.parentNode;}
 if(!t || !t.getAttribute){return;}
 if(t.getAttribute('target')){return;}
 var h=t.getAttribute('href');
 if(!isLocal(h)){return;}
 if(e.preventDefault){e.preventDefault();}else{e.returnValue=false;}
 window.location.href=t.href;
 return false;
}
function addAppleHomeBar(){
 if(!window.navigator.standalone){return;}
 var p=(location.pathname||'').toLowerCase();
 if(p.indexOf('apple')==-1){return;}
 if(document.getElementById('www-app-homebar')){return;}
 var b=document.getElementsByTagName('body')[0];
 if(!b){return;}
 var bar=document.createElement('div');
 bar.id='www-app-homebar';
 bar.style.cssText='height:30px;line-height:30px;text-align:center;background:#2f6da9;background:-webkit-gradient(linear,left top,left bottom,from(#7fb4e7),color-stop(.48,#3d7fbd),color-stop(.52,#286aa8),to(#164d82));border-bottom:1px solid #1d3550;position:relative;font-family:Georgia,Times New Roman,serif;font-style:italic;color:#fff;font-size:15px;text-shadow:0 -1px 0 #173b60;';
 var a=document.createElement('a');
 a.href='index.html';
 a.innerHTML='WWW';
 a.style.cssText='position:absolute;left:6px;top:3px;height:24px;line-height:23px;padding:0 9px;color:#fff;text-decoration:none;font:bold 11px Helvetica,Arial,sans-serif;font-style:normal;border:1px solid #2d3b52;-webkit-border-radius:6px;border-radius:6px;background:#566c89;background:-webkit-gradient(linear,left top,left bottom,from(#7187a2),color-stop(.5,#596f8c),to(#425775));text-shadow:0 -1px 0 #222;';
 bar.appendChild(a);
 var label=document.createTextNode('World Wide Web');
 bar.appendChild(label);
 b.insertBefore(bar,b.firstChild);
}
function ready(){
 addAppleHomeBar();
}
if(document.addEventListener){
 document.addEventListener('click',keepInside,false);
 document.addEventListener('DOMContentLoaded',ready,false);
}else if(document.attachEvent){
 document.attachEvent('onclick',keepInside);
 window.attachEvent('onload',ready);
}
if(window.applicationCache && window.applicationCache.addEventListener){
 window.applicationCache.addEventListener('updateready',function(){
  try{
   if(window.applicationCache.status==window.applicationCache.UPDATEREADY){
    window.applicationCache.swapCache();
    window.location.reload();
   }
  }catch(e){}
 },false);
}
})();
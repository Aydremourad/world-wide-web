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
function ready(){
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
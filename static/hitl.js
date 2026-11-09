(function(){
  var $=function(id){return document.getElementById(id)};
  document.addEventListener('keydown',function(e){   // Alt+Left / Alt+Right: previous / next item
    if(!e.altKey||e.ctrlKey||e.metaKey||e.shiftKey) return;
    if(e.target.closest&&e.target.closest('textarea,input,[contenteditable]')) return;
    var a=document.querySelector(e.key==='ArrowLeft'?'link[rel=prev]':e.key==='ArrowRight'?'link[rel=next]':null);
    if(a){e.preventDefault(); location.href=a.href}
  });
  if(!window.HITL) return;               // opened as a file: no server, no chat
  var quote="", opener=null;
  var ask=$('hitl-ask'), open=$('hitl-open'), chat=$('hitl-chat'), log=$('hitl-log'), q=$('hitl-q'),
      qt=$('hitl-quote'), qb=$('hitl-qbox'), form=$('hitl-form');
  open.classList.add('on');
  // questions the brief does not precompute; your bubble shows the button you pressed
  document.querySelectorAll('[data-ask]').forEach(function(b){
    b.hidden=false; b.addEventListener('click',function(){hitlAsk(b.dataset.ask,'',b.textContent.trim())})});
  function show(){opener=document.activeElement; chat.classList.add('open'); chat.setAttribute('aria-hidden','false');
    document.documentElement.classList.add('hitl-open'); open.classList.remove('on'); q.focus()}
  function hide(){chat.classList.remove('open'); chat.setAttribute('aria-hidden','true');
    document.documentElement.classList.remove('hitl-open'); open.classList.add('on');
    (opener&&document.contains(opener)&&opener!==document.body?opener:open).focus()}
  function setQuote(t){quote=t; qt.textContent=t; qb.classList.toggle('on',!!t)}
  function place(){
    var s=window.getSelection(), t=s&&s.rangeCount?s.toString().trim():"";
    var el=s&&s.anchorNode?(s.anchorNode.nodeType===1?s.anchorNode:s.anchorNode.parentElement):null;
    if(!t||form.contains(s.anchorNode)||(el&&el.closest('button,input,textarea,select,a,nav,.qact,.qstate,#hitl-decisions'))){
      ask.classList.remove('on'); return}
    ask.classList.add('on'); ask.dataset.text=t.slice(0,1500);
    // 10 below the selection, kept inside the viewport (above it when there is no room below)
    var r=s.getRangeAt(0).getBoundingClientRect(), w=ask.offsetWidth||150, h=ask.offsetHeight||44;
    var x=Math.max(8,Math.min(r.left,document.documentElement.clientWidth-w-8));
    var y=r.bottom+10+h>window.innerHeight-8&&r.top-10-h>=8?r.top-10-h:r.bottom+10;
    ask.style.left=(window.scrollX+x)+'px'; ask.style.top=(window.scrollY+y)+'px';
  }
  document.addEventListener('mouseup',function(e){
    if(e.target.closest&&e.target.closest('button,input,textarea,select,a')) return;  // a click on a control is not a selection
    if(e.target!==ask&&!ask.contains(e.target)) setTimeout(place,0)});
  document.addEventListener('keyup',function(e){if(e.shiftKey||e.key==='Shift') place()});
  ask.addEventListener('click',function(){setQuote(ask.dataset.text||""); ask.classList.remove('on'); show()});
  open.addEventListener('click',show); $('hitl-close').addEventListener('click',hide);
  $('hitl-unquote').addEventListener('click',function(){setQuote(''); q.focus()});
  document.addEventListener('keydown',function(e){
    if(e.ctrlKey&&e.shiftKey&&!e.altKey&&(e.key==='A'||e.key==='a')){   // keyboard path to Ask about this
      var s=window.getSelection(), t=s&&s.rangeCount&&!form.contains(s.anchorNode)?s.toString().trim():"";
      e.preventDefault(); if(t) setQuote(t.slice(0,1500)); ask.classList.remove('on'); show(); return;
    }
    if(e.key!=='Escape') return;
    if(ask.classList.contains('on')) ask.classList.remove('on');
    else if(chat.classList.contains('open')) hide();
  });
  function send(label){
    var text=q.value.trim(); if(!text&&!quote) return;
    var me=document.createElement('div'); me.className='me';
    if(quote){var b=document.createElement('blockquote'); b.textContent=quote; me.appendChild(b)}
    me.appendChild(document.createTextNode(label||text||'What does this mean?')); log.appendChild(me);
    var it=document.createElement('div'); it.className='it wait'; it.textContent='Thinking…'; it.setAttribute('aria-busy','true'); log.appendChild(it);
    log.scrollTop=log.scrollHeight;
    var body=JSON.stringify({question:text,quote:quote,item:document.body.dataset.item||"",title:document.title});
    q.value=''; setQuote(''); $('hitl-send').disabled=true;
    function done(){it.classList.remove('wait'); it.removeAttribute('aria-busy')}
    fetch('/ask',{method:'POST',headers:{'Content-Type':'application/json','X-HITL-Token':HITL.token},body:body})
      .then(function(r){return r.json()}).then(function(j){
        done(); if(j.error){it.textContent='No answer. '+j.error} else {it.innerHTML=j.html}
      }).catch(function(e){done(); it.textContent='No answer. '+e})
      .finally(function(){$('hitl-send').disabled=false; log.scrollTop=log.scrollHeight});
  }
  $('hitl-send').addEventListener('click',function(){send()});
  q.addEventListener('keydown',function(e){if(e.key==='Enter'&&(e.ctrlKey||e.metaKey)){e.preventDefault();send()}});
  function hitlAsk(question,quoteText,label){setQuote(quoteText||''); show(); q.value=question; send(label)}
  window.hitlAsk=hitlAsk;
})();

(function(){
  if(!window.HITL) return;   // opened as a file: decisions are read-only
  function icon(size,paths){return '<svg width="'+size+'" height="'+size+'" viewBox="0 0 20 20" aria-hidden="true" fill="none" '+
    'stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round">'+paths+'</svg>'}
  var ICON={check:icon(16,'<path d="M4.5 10.5l3.5 3.5 7.5-8"/>'),   // checkmark and doc.on.doc (DESIGN.md 5)
    copy:icon(18,'<rect x="7" y="7" width="9.5" height="10.5" rx="2"/><path d="M13 7V5.5a2 2 0 0 0-2-2H5.5a2 2 0 0 0-2 2V12a2 2 0 0 0 2 2H7"/>')};
  function api(path,obj){return fetch(path,{method:'POST',headers:{'Content-Type':'application/json','X-HITL-Token':HITL.token},
    body:JSON.stringify(obj||{})}).then(function(r){return r.json().then(function(j){j._status=r.status; return j})})}
  function hhmm(ts){try{var d=new Date(ts); return d.toLocaleTimeString([], {hour:'2-digit',minute:'2-digit'})}catch(e){return ts}}
  function el(tag,cls,text){var e=document.createElement(tag); if(cls) e.className=cls; if(text!=null) e.textContent=text; return e}
  function btn(text,fn,cls,icon){var b=el('button',cls||''); b.type='button'; if(icon) b.innerHTML=ICON[icon];
    b.appendChild(document.createTextNode(text)); b.addEventListener('click',fn); return b}
  function clip(t){return navigator.clipboard&&navigator.clipboard.writeText?navigator.clipboard.writeText(t):Promise.reject()}
  function trim(v){return v.trim().replace(/[.\s]+$/,'')}
  // the reason a saved answer is out of date: a tooltip and screen-reader text, never a sentence on the page
  function why(stale){var s=(stale||[]).join(' '), code=/code changed/.test(s), ev=/new evidence/.test(s);
    return code&&ev?'The code changed; new evidence.':code?'The code changed.':'New evidence.'}
  function staleMark(stale){var m=el('span','smark','Out of date'); m.title=why(stale);
    m.appendChild(el('span','sr',' ('+why(stale)+')')); return m}
  // copying failed: the exact text, selected, under the line it belongs to
  function failField(after,text){
    var f=el('div','cfail'), p=el('p','','Copy failed. Press Ctrl+C.'), t=el('textarea'); t.readOnly=true; t.value=text;
    t.rows=Math.min(8,text.split('\n').length+1); f.appendChild(p); f.appendChild(t);
    after.parentNode.insertBefore(f,after.nextSibling); t.focus(); t.select(); return f}

  // One commit model for every answer: choosing a listed option or typing your
  // own answer only selects it; Save decision (or Enter in the field) commits it. The
  // line under the options is always there and only changes what it says.
  function msg(kind,text){
    var m=el('span','msg '+kind); if(kind==='ok') m.innerHTML=ICON.check;
    m.appendChild(el('span','',text)); return m}
  function own(li){var r=li.querySelector('.own'); return r&&{row:r,t:r.querySelector('.own-t')}}
  function fit(t){t.style.height='auto'; t.style.height=t.scrollHeight+'px'}
  // li.dataset: saved = the committed answer ('' if none); sel = the selected
  // option; other = '1' while your own answer is selected; savedown = '1' when the
  // saved answer is your own. Only clicks, arrow keys and typing change the selection, never blur.
  function pending(li){
    var o=own(li), v=li.dataset.other==='1'?(o?trim(o.t.value):''):(li.dataset.sel||'');
    return v&&v!==li.dataset.saved?v:'';
  }
  function view(li){
    var o=own(li), dr=li._dr, other=li.dataset.other==='1', own1=li.dataset.savedown==='1',
        text=o?trim(o.t.value):'';
    if(!dr) return 'choose';
    if(dr.delivered) return 'sent';
    var changed=other?!own1||text!==li.dataset.saved:(li.dataset.sel||'')!==(own1?'':li.dataset.saved);
    return changed?'change':dr.stale&&dr.stale.length?'stale':'saved';
  }
  function render(li){
    var o=own(li), dr=li._dr, st=li.querySelector('.qstate'), other=li.dataset.other==='1', v=view(li);
    li.querySelectorAll('.opt').forEach(function(b){
      b.setAttribute('aria-checked',!other&&b.dataset.opt===li.dataset.sel?'true':'false')});
    if(o){o.row.setAttribute('aria-checked',other?'true':'false'); fit(o.t)}
    // roving tabindex: Tab enters the group at the checked radio, or the first
    var stops=radios(li), on=stops.filter(function(r){return checked(li,r)})[0]||stops[0];
    stops.forEach(function(r){r.tabIndex=r===on?0:-1});
    if(st.dataset.view!==v||li._err){   // same line: keep it, and keep focus where it is
      st.dataset.view=v; st.textContent=''; st.hidden=false;
      var f=li.querySelector('.cfail'); if(f) f.remove();
      if(li._err){st.appendChild(msg('err','Not saved. '+li._err)); li._err=''}
      if(v==='sent') st.appendChild(msg('ok','Sent at '+hhmm(dr.delivered)+'.'));
      else if(v==='choose'||v==='change'){
        st.appendChild(btn('Save decision',function(){commit(li,pending(li))},'commit'));
        if(v==='change') st.appendChild(btn('Cancel',function(){restore(li)},'link'));
      } else if(v==='stale'){
        st.appendChild(btn('Save again',function(){commit(li,li.dataset.saved)},'link'));
        st.appendChild(btn('Undo',function(){undo(li)},'link'));
      } else {
        st.appendChild(msg('ok','Saved.'));
        st.appendChild(btn('Copy',function(){copy(li)},'soft','copy'));
        st.appendChild(btn('Undo',function(){undo(li)},'link'));
      }
    }
    li.classList.toggle('decided',v==='sent');
    var c=st.querySelector('.commit'); if(c) c.disabled=!pending(li);
    // the saved answer, out of date: the mark sits where "Suggested" does
    li.querySelectorAll('.smark,.mark.only').forEach(function(m){m.remove()});
    if(v==='stale'){
      var row=li.dataset.savedown==='1'?(o&&o.row):[].filter.call(li.querySelectorAll('.opt'),function(b){return b.dataset.opt===li.dataset.saved})[0];
      if(row){
        var mk=row.querySelector('.mark'), sm=staleMark(dr.stale);
        if(mk){sm.insertBefore(document.createTextNode(' · '),sm.firstChild); mk.appendChild(sm)}
        else{mk=el('span','mark only'); mk.appendChild(sm); var after=row.querySelector('.ot,.own-t'); after.parentNode.insertBefore(mk,after.nextSibling)}
      }
    }
  }
  function copy(li){
    var st=li.querySelector('.qstate');
    api('/send',{id:li._dr.id}).then(function(r){
      if(r._status===200) return clip(r.text).then(function(){say(st,'ok','Copied.')},function(){
        say(st,'err','Copy failed. Press Ctrl+C.'); var f=li.querySelector('.cfail'); if(f) f.remove(); failField(st,r.text).querySelector('p').hidden=true});
      if(r.stale){li._dr.stale=r.stale; render(li); return}
      refresh(li);   // already sent, or gone
    }).catch(function(e){li._err=String(e); render(li)});
  }
  function say(st,kind,text){var m=st.querySelector('.msg'), n=msg(kind,text); if(m) st.replaceChild(n,m); else st.insertBefore(n,st.firstChild)}
  function undo(li){   // the draft goes; your answer stays selected, unsaved
    api('/withdraw',{id:li._dr.id}).then(function(){
      li._dr=null; li.dataset.draft=''; li.dataset.saved=''; li.dataset.savedown=''; render(li)});
  }
  function refresh(li){
    api('/drafts').then(function(j){
      paint(li,(j.drafts||[]).filter(function(d){return d.decision===li.dataset.item+':'+li.dataset.did})[0]||null)});
  }
  function restore(li){   // the selection goes back to what is saved
    var o=own(li), dr=li._dr, known=dr&&[].some.call(li.querySelectorAll('.opt'),function(b){return b.dataset.opt===dr.option});
    li.dataset.saved=dr?dr.option:''; li.dataset.sel=known?dr.option:''; li.dataset.other=dr&&!known?'1':''; li.dataset.savedown=li.dataset.other;
    if(o){o.t.value=dr&&!known?dr.option:''; o.t.disabled=!!(dr&&dr.delivered); o.row.hidden=!!(dr&&dr.delivered&&!o.t.value)}
    render(li);
  }
  function paint(li,dr){
    li._dr=dr; li.dataset.draft=dr?dr.id:'';
    li.querySelectorAll('.opt').forEach(function(b){b.disabled=!!(dr&&dr.delivered)});
    restore(li);
  }
  function commit(li,v){
    if(!v) return;
    api('/decide',{item:li.dataset.item,did:li.dataset.did,question:li.dataset.question,ref:li.dataset.ref,
                   brief:li.dataset.brief,option:v}).then(function(j){
      if(j.error){li._err=j.error; render(li); return}
      paint(li,{id:j.id,option:v,stale:[],delivered:null});
    }).catch(function(e){li._err=String(e); render(li)});
  }
  // the answers are one radio group: the options, then the field for your own answer
  function radios(li){var o=own(li); return [].slice.call(li.querySelectorAll('.opt')).concat(o&&!o.row.hidden?[o.t]:[])
    .filter(function(r){return !r.disabled})}
  function checked(li,r){return r.classList.contains('own-t')?li.dataset.other==='1':li.dataset.other!=='1'&&r.dataset.opt===li.dataset.sel}
  function pick(li,r){   // move to a radio and select it, as native radios do
    if(r.classList.contains('own-t')) r.focus();   // focusing the field selects it
    else{li.dataset.sel=r.dataset.opt; li.dataset.other=''; render(li); r.focus()}
  }
  function arrows(li,e){
    var k=e.key, back=k==='ArrowUp'||k==='ArrowLeft', fwd=k==='ArrowDown'||k==='ArrowRight';
    if(!back&&!fwd) return;
    var t=e.target, rs=radios(li), i=rs.indexOf(t); if(i<0) return;
    // in the field the arrows edit text; only Up or Left at its very start leaves it
    if(t.classList.contains('own-t')&&(fwd||t.selectionStart!==0||t.selectionEnd!==0)) return;
    e.preventDefault(); pick(li,rs[(i+(fwd?1:-1)+rs.length)%rs.length]);
  }
  var items=document.querySelectorAll('li.q[data-did]');
  items.forEach(function(li){
    var group=li.querySelector('.opts'); if(group) group.addEventListener('keydown',function(e){arrows(li,e)});
    li._dr=null; li.dataset.saved=''; li.dataset.sel=''; li.dataset.other='';
    li.querySelectorAll('.opt').forEach(function(b){b.disabled=false; b.addEventListener('click',function(){
      li.dataset.sel=b.dataset.opt; li.dataset.other=''; render(li)})});
    var o=own(li);
    if(o){
      o.row.hidden=false;
      o.row.addEventListener('click',function(e){if(e.target===o.row) o.t.focus()});
      o.t.addEventListener('focus',function(){
        if(li.dataset.other!=='1'){li.dataset.other='1'; render(li)}});
      o.t.addEventListener('input',function(){render(li)});
      o.t.addEventListener('keydown',function(e){if(e.key==='Enter'&&!e.shiftKey&&!e.isComposing){e.preventDefault(); commit(li,pending(li))}});
    }
    render(li);
    var act=li.querySelector('.qact'); if(act) act.hidden=false;
    var opts=[].map.call(li.querySelectorAll('.opt'),function(o){return '- '+o.dataset.opt}).join('\n');
    var ex=li.querySelector('.explain'), gr=li.querySelector('.grill');
    if(ex) ex.addEventListener('click',function(){window.hitlAsk(ex.dataset.q+'\n'+opts, li.dataset.question, ex.textContent)});
    if(gr) gr.addEventListener('click',function(){window.hitlAsk(gr.dataset.q+'\n'+opts, li.dataset.question, gr.textContent)});
  });

  // the index: your saved decisions, each ready to copy
  function strip(drafts){
    var s=document.getElementById('hitl-decisions'); if(!s) return;
    var open=drafts.filter(function(d){return !d.delivered}), sent=drafts.length-open.length;
    if(!open.length&&!sent) return;
    s.hidden=false;
    var ul=s.querySelector('ul');
    ul.hidden=!open.length;
    open.forEach(function(d){
      var m=/^#(\d+):\s*([^\n]*)/.exec(d.text||''), key=(d.decision||'').split(':'),
          n=m?m[1]:key[0], did=key[1]||'', href='i'+n+'.html'+(did?'#q'+n+'-'+did:'');
      var li=el('li'), main=el('div','dmain'), ans=el('p','dans',d.option||''), q=el('a','dq'),
          act=el('div','dact'), line=el('p','dline'), r={};
      q.href=href; var qt=el('span','dqt'); qt.appendChild(el('span','dno','#'+n)); qt.appendChild(document.createTextNode(m?m[2]:'')); q.appendChild(qt);
      line.setAttribute('aria-live','polite');
      main.appendChild(ans); main.appendChild(q); li.appendChild(main); li.appendChild(act); li.appendChild(line);
      r.paint=function(){
        act.textContent=''; var old=ans.querySelector('.mark'); if(old) old.remove();
        if(d.stale&&d.stale.length){
          // out of date: no Copy; the mark says why, and the row opens the decision
          var mk=el('span','mark'); mk.appendChild(staleMark(d.stale)); ans.appendChild(mk);
        } else act.appendChild(btn('Copy',function(){
          var f=li.querySelector('.cfail'); if(f) f.remove(); line.textContent='';
          api('/send',{id:d.id}).then(function(x){
            if(x._status===200) return clip(x.text).then(function(){line.textContent='Copied.'},function(){failField(line,x.text)});
            if(x.stale){d.stale=x.stale; r.paint(); return}
            line.textContent=x._status===409?'Already sent.':x.error||'';
          }).catch(function(e){line.textContent=String(e)});
        },'soft','copy'));
      };
      r.paint(); ul.appendChild(li);
    });
    var p=s.querySelector('.dsent'); p.hidden=!sent; p.textContent=sent+' already sent.';
  }

  api('/drafts').then(function(j){return j.drafts||[]},function(){return []}).then(function(drafts){
    var by={};
    drafts.forEach(function(d){if(d.decision) by[d.decision]=d});
    items.forEach(function(li){
      paint(li,by[li.dataset.item+':'+li.dataset.did]||null)});
    strip(drafts);
  });
})();

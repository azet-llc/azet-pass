// Korean browsers go to the Korean help page (a file, not inline: the vault's policy allows scripts from this site only)
try{if((navigator.language||'').toLowerCase().startsWith('ko')&&!/lang=en/.test(location.search))location.replace('ko.html'+location.hash)}catch(e){}

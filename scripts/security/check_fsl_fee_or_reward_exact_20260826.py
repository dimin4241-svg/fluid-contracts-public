#!/usr/bin/env python3
import json, time
from datetime import datetime, timezone
import requests

SELECTOR='0xe47a882d'
TARGETS=[
('Base',8453,'0x4563134183e45D9502015db14B263E31781099bB'),('Base',8453,'0x983107BB3dcb71f3A30176114D8a17c454A62514'),('Base',8453,'0x3F6f85e3EDD95Db7f5D33b287D748dfEA64d92a6'),('Base',8453,'0x4f0C96408aF08473051Ea3EA1FF3e4F288115A5A'),
('Plasma',9745,'0x983107BB3dcb71f3A30176114D8a17c454A62514'),('Plasma',9745,'0x4f0C96408aF08473051Ea3EA1FF3e4F288115A5A'),
('Polygon',137,'0xa779B6736385930145F4856226Cd3E3691B72458'),('Polygon',137,'0x4563134183e45D9502015db14B263E31781099bB'),('Polygon',137,'0x3F6f85e3EDD95Db7f5D33b287D748dfEA64d92a6'),('Polygon',137,'0x4f0C96408aF08473051Ea3EA1FF3e4F288115A5A'),
('Arbitrum',42161,'0x82C53239c4CFC89A8E55A691422af24c18A944b1'),('Arbitrum',42161,'0x1F0bFd9862ae58208d26db0d80797974434EC013'),('Arbitrum',42161,'0xdC1dF9E55f3B7EBD4F19001b294d1e537320BC2E'),
('Ethereum',1,'0xb210249Bc59FE77D29eb5F0e566D60CB2B010EF1'),('Ethereum',1,'0x9b1f75ea07723F331996831f6d04AD4900d1A3B3'),('Ethereum',1,'0xD2245ee5C3099d65a3d0fdCecA0f71Cc4aA8f0FF'),('Ethereum',1,'0x44aE65F0d82E339c31c3Db9d4f82aB4D5d2B06B2'),('Ethereum',1,'0x10705D774fBE0a3802d7a915E23F6f2c109Fd77f'),('Ethereum',1,'0x7cA3814E21E96758d27e4e07B8d021DE70fC4Db6'),('Ethereum',1,'0x6Ee1e0FC4435571AABd95ecd441dE93C804d7f70'),('Ethereum',1,'0xe3eA95fBd0B27D3fF27e04a43aa5C4361376597c')]
RPCS={1:['https://ethereum-rpc.publicnode.com','https://rpc.ankr.com/eth'],8453:['https://base-rpc.publicnode.com','https://mainnet.base.org'],137:['https://polygon-bor-rpc.publicnode.com','https://polygon-rpc.com'],42161:['https://arbitrum-one-rpc.publicnode.com','https://arb1.arbitrum.io/rpc'],9745:['https://rpc.plasma.to','https://plasma-rpc.publicnode.com']}

def url(cid,a): return f'https://api.routescan.io/v2/network/mainnet/evm/{cid}/etherscan/api?action=eth_call&data={SELECTOR}&module=proxy&tag=latest&to={a}'
def dec(x):
 v=int(x,16)&0xffffffff
 return v-(1<<32) if v&0x80000000 else v

def route(s,u):
 errs=[]
 for i in range(3):
  try:
   r=s.get(u,timeout=25); r.raise_for_status(); p=r.json(); x=p.get('result')
   if isinstance(x,str) and x.startswith('0x') and len(x)>2: return x,None
   errs.append(repr(p))
  except Exception as e: errs.append(repr(e))
  time.sleep(1+i)
 return None,' | '.join(errs)

def rpc(s,cid,a):
 errs=[]
 for ep in RPCS[cid]:
  try:
   p={'jsonrpc':'2.0','id':1,'method':'eth_call','params':[{'to':a,'data':SELECTOR},'latest']}
   r=s.post(ep,json=p,timeout=25); r.raise_for_status(); b=r.json(); x=b.get('result')
   if isinstance(x,str) and x.startswith('0x') and len(x)>2:return x,ep,None
   errs.append(f'{ep}: {b!r}')
  except Exception as e: errs.append(f'{ep}: {e!r}')
 return None,None,' | '.join(errs)

def main():
 s=requests.Session(); s.headers['User-Agent']='fsl-exact-runtime-check/1.0'
 now=datetime.now(timezone.utc).isoformat(); rows=[]; nz=[]; unresolved=[]
 for n,c,a in TARGETS:
  u=url(c,a); rr,re=route(s,u); row={'network':n,'chain_id':c,'address':a,'routescan_url':u,'checked_at_utc':now,'routescan_result':rr}
  if rr is None:
   fr,ep,fe=rpc(s,c,a); row.update({'routescan_error':re,'fallback_result':fr,'fallback_rpc':ep,'fallback_error':fe})
   if fr is None: row['status']='unresolved'; unresolved.append(row); rows.append(row); continue
   raw=dec(fr); row.update({'raw_int32':raw,'annual_percent':raw/10000,'status':'fallback_confirmed'})
   if raw!=0:
    # one fallback is not independent of failed Routescan, so require second independent fallback
    others=[x for x in RPCS[c] if x!=ep]; confirmed=False
    for ep2 in others:
     try:
      p={'jsonrpc':'2.0','id':2,'method':'eth_call','params':[{'to':a,'data':SELECTOR},'latest']}; q=s.post(ep2,json=p,timeout=25); q.raise_for_status(); b=q.json(); x=b.get('result')
      if isinstance(x,str) and x.startswith('0x') and len(x)>2 and dec(x)==raw: row.update({'confirm_result':x,'confirm_rpc':ep2}); confirmed=True; break
     except Exception: pass
    if confirmed: row['status']='confirmed_nonzero'; nz.append(row)
    else: row['status']='unresolved_nonzero'; unresolved.append(row)
   rows.append(row); continue
  raw=dec(rr); row.update({'raw_int32':raw,'annual_percent':raw/10000})
  if raw==0: row['status']='routescan_zero'; rows.append(row); continue
  fr,ep,fe=rpc(s,c,a); row.update({'fallback_result':fr,'fallback_rpc':ep,'fallback_error':fe})
  if fr is not None and dec(fr)==raw: row['status']='confirmed_nonzero'; nz.append(row)
  else: row['status']='unresolved_nonzero'; unresolved.append(row)
  rows.append(row)
 out={'checked_at_utc':now,'target_count':len(TARGETS),'results':rows,'confirmed_nonzero':nz,'unresolved':unresolved,'all_21_confirmed_zero':len(rows)==21 and not nz and not unresolved and all(r['raw_int32']==0 for r in rows)}
 print(json.dumps(out,indent=2))

if __name__=='__main__': main()

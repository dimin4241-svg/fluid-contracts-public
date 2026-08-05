#!/usr/bin/env python3
from __future__ import annotations
import json, sys, time
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

def decode_int32(x):
    v=int(x,16)&0xffffffff
    return v-(1<<32) if v&0x80000000 else v

def routescan_url(cid,a):
    return f'https://api.routescan.io/v2/network/mainnet/evm/{cid}/etherscan/api?module=proxy&action=eth_call&to={a}&data={SELECTOR}&tag=latest'

def get_routescan(s,u):
    err=''
    for i in range(3):
        try:
            r=s.get(u,timeout=30); r.raise_for_status(); j=r.json(); x=j.get('result')
            if isinstance(x,str) and x.startswith('0x'): return x,'routescan'
            err=f'invalid payload {j}'
        except Exception as e: err=repr(e)
        time.sleep(i+1)
    raise RuntimeError(err)

def get_rpc(s,cid,a):
    p={'jsonrpc':'2.0','id':1,'method':'eth_call','params':[{'to':a,'data':SELECTOR},'latest']}; errs=[]
    for rpc in RPCS.get(cid,[]):
        try:
            r=s.post(rpc,json=p,timeout=30); r.raise_for_status(); j=r.json(); x=j.get('result')
            if isinstance(x,str) and x.startswith('0x'): return x,rpc
            errs.append(f'{rpc}: {j}')
        except Exception as e: errs.append(f'{rpc}: {e!r}')
    raise RuntimeError('; '.join(errs))

def main():
    s=requests.Session(); s.headers['User-Agent']='fluid-fsl-watch/1.0'; now=datetime.now(timezone.utc).isoformat(); rows=[]; failures=[]
    for net,cid,a in TARGETS:
        u=routescan_url(cid,a)
        try:
            try: x,source=get_routescan(s,u)
            except Exception: x,source=get_rpc(s,cid,a)
            raw=decode_int32(x); rows.append({'network':net,'chain_id':cid,'address':a,'routescan_url':u,'source':source,'result':x,'raw_int32':raw,'annual_percent':raw/10000,'checked_at_utc':now})
        except Exception as e: failures.append({'network':net,'chain_id':cid,'address':a,'routescan_url':u,'error':repr(e)})
    out={'checked_at_utc':now,'target_count':len(TARGETS),'success_count':len(rows),'failure_count':len(failures),'nonzero':[r for r in rows if r['raw_int32']!=0],'results':rows,'failures':failures}
    print(json.dumps(out,indent=2))
    return 2 if failures else (10 if out['nonzero'] else 0)
if __name__=='__main__': sys.exit(main())
# automation refresh 2026-08-05T20:53Z

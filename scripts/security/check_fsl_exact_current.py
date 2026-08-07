#!/usr/bin/env python3
from __future__ import annotations
import json, time
from datetime import datetime, timezone
import requests

SELECTOR='0xe47a882d'
TARGETS=[
('Base',8453,'0x4563134183e45D9502015db14B263E31781099bB','https://api.routescan.io/v2/network/mainnet/evm/8453/etherscan/api?action=eth_call&data=0xe47a882d&module=proxy&tag=latest&to=0x4563134183e45D9502015db14B263E31781099bB'),
('Base',8453,'0x983107BB3dcb71f3A30176114D8a17c454A62514','https://api.routescan.io/v2/network/mainnet/evm/8453/etherscan/api?action=eth_call&data=0xe47a882d&module=proxy&tag=latest&to=0x983107BB3dcb71f3A30176114D8a17c454A62514'),
('Base',8453,'0x3F6f85e3EDD95Db7f5D33b287D748dfEA64d92a6','https://api.routescan.io/v2/network/mainnet/evm/8453/etherscan/api?action=eth_call&data=0xe47a882d&module=proxy&tag=latest&to=0x3F6f85e3EDD95Db7f5D33b287D748dfEA64d92a6'),
('Base',8453,'0x4f0C96408aF08473051Ea3EA1FF3e4F288115A5A','https://api.routescan.io/v2/network/mainnet/evm/8453/etherscan/api?action=eth_call&data=0xe47a882d&module=proxy&tag=latest&to=0x4f0C96408aF08473051Ea3EA1FF3e4F288115A5A'),
('Plasma',9745,'0x983107BB3dcb71f3A30176114D8a17c454A62514','https://api.routescan.io/v2/network/mainnet/evm/9745/etherscan/api?action=eth_call&data=0xe47a882d&module=proxy&tag=latest&to=0x983107BB3dcb71f3A30176114D8a17c454A62514'),
('Plasma',9745,'0x4f0C96408aF08473051Ea3EA1FF3e4F288115A5A','https://api.routescan.io/v2/network/mainnet/evm/9745/etherscan/api?action=eth_call&data=0xe47a882d&module=proxy&tag=latest&to=0x4f0C96408aF08473051Ea3EA1FF3e4F288115A5A'),
('Polygon',137,'0xa779B6736385930145F4856226Cd3E3691B72458','https://api.routescan.io/v2/network/mainnet/evm/137/etherscan/api?action=eth_call&data=0xe47a882d&module=proxy&tag=latest&to=0xa779B6736385930145F4856226Cd3E3691B72458'),
('Polygon',137,'0x4563134183e45D9502015db14B263E31781099bB','https://api.routescan.io/v2/network/mainnet/evm/137/etherscan/api?action=eth_call&data=0xe47a882d&module=proxy&tag=latest&to=0x4563134183e45D9502015db14B263E31781099bB'),
('Polygon',137,'0x3F6f85e3EDD95Db7f5D33b287D748dfEA64d92a6','https://api.routescan.io/v2/network/mainnet/evm/137/etherscan/api?action=eth_call&data=0xe47a882d&module=proxy&tag=latest&to=0x3F6f85e3EDD95Db7f5D33b287D748dfEA64d92a6'),
('Polygon',137,'0x4f0C96408aF08473051Ea3EA1FF3e4F288115A5A','https://api.routescan.io/v2/network/mainnet/evm/137/etherscan/api?action=eth_call&data=0xe47a882d&module=proxy&tag=latest&to=0x4f0C96408aF08473051Ea3EA1FF3e4F288115A5A'),
('Arbitrum',42161,'0x82C53239c4CFC89A8E55A691422af24c18A944b1','https://api.routescan.io/v2/network/mainnet/evm/42161/etherscan/api?action=eth_call&data=0xe47a882d&module=proxy&tag=latest&to=0x82C53239c4CFC89A8E55A691422af24c18A944b1'),
('Arbitrum',42161,'0x1F0bFd9862ae58208d26db0d80797974434EC013','https://api.routescan.io/v2/network/mainnet/evm/42161/etherscan/api?action=eth_call&data=0xe47a882d&module=proxy&tag=latest&to=0x1F0bFd9862ae58208d26db0d80797974434EC013'),
('Arbitrum',42161,'0xdC1dF9E55f3B7EBD4F19001b294d1e537320BC2E','https://api.routescan.io/v2/network/mainnet/evm/42161/etherscan/api?action=eth_call&data=0xe47a882d&module=proxy&tag=latest&to=0xdC1dF9E55f3B7EBD4F19001b294d1e537320BC2E'),
('Ethereum',1,'0xb210249Bc59FE77D29eb5F0e566D60CB2B010EF1','https://api.routescan.io/v2/network/mainnet/evm/1/etherscan/api?action=eth_call&data=0xe47a882d&module=proxy&tag=latest&to=0xb210249Bc59FE77D29eb5F0e566D60CB2B010EF1'),
('Ethereum',1,'0x9b1f75ea07723F331996831f6d04AD4900d1A3B3','https://api.routescan.io/v2/network/mainnet/evm/1/etherscan/api?action=eth_call&data=0xe47a882d&module=proxy&tag=latest&to=0x9b1f75ea07723F331996831f6d04AD4900d1A3B3'),
('Ethereum',1,'0xD2245ee5C3099d65a3d0fdCecA0f71Cc4aA8f0FF','https://api.routescan.io/v2/network/mainnet/evm/1/etherscan/api?action=eth_call&data=0xe47a882d&module=proxy&tag=latest&to=0xD2245ee5C3099d65a3d0fdCecA0f71Cc4aA8f0FF'),
('Ethereum',1,'0x44aE65F0d82E339c31c3Db9d4f82aB4D5d2B06B2','https://api.routescan.io/v2/network/mainnet/evm/1/etherscan/api?action=eth_call&data=0xe47a882d&module=proxy&tag=latest&to=0x44aE65F0d82E339c31c3Db9d4f82aB4D5d2B06B2'),
('Ethereum',1,'0x10705D774fBE0a3802d7a915E23F6f2c109Fd77f','https://api.routescan.io/v2/network/mainnet/evm/1/etherscan/api?action=eth_call&data=0xe47a882d&module=proxy&tag=latest&to=0x10705D774fBE0a3802d7a915E23F6f2c109Fd77f'),
('Ethereum',1,'0x7cA3814E21E96758d27e4e07B8d021DE70fC4Db6','https://api.routescan.io/v2/network/mainnet/evm/1/etherscan/api?action=eth_call&data=0xe47a882d&module=proxy&tag=latest&to=0x7cA3814E21E96758d27e4e07B8d021DE70fC4Db6'),
('Ethereum',1,'0x6Ee1e0FC4435571AABd95ecd441dE93C804d7f70','https://api.routescan.io/v2/network/mainnet/evm/1/etherscan/api?action=eth_call&data=0xe47a882d&module=proxy&tag=latest&to=0x6Ee1e0FC4435571AABd95ecd441dE93C804d7f70'),
('Ethereum',1,'0xe3eA95fBd0B27D3fF27e04a43aa5C4361376597c','https://api.routescan.io/v2/network/mainnet/evm/1/etherscan/api?action=eth_call&data=0xe47a882d&module=proxy&tag=latest&to=0xe3eA95fBd0B27D3fF27e04a43aa5C4361376597c'),
]
RPCS={1:['https://ethereum-rpc.publicnode.com','https://eth.llamarpc.com','https://rpc.ankr.com/eth'],8453:['https://base-rpc.publicnode.com','https://mainnet.base.org'],137:['https://polygon-bor-rpc.publicnode.com','https://polygon-rpc.com'],42161:['https://arbitrum-one-rpc.publicnode.com','https://arb1.arbitrum.io/rpc'],9745:['https://rpc.plasma.to','https://plasma-rpc.publicnode.com','https://plasma.drpc.org']}

def dec32(x):
    v=int(x,16)&0xffffffff
    return v-(1<<32) if v&0x80000000 else v

def rpc_call(s,url,address):
    p={'jsonrpc':'2.0','id':1,'method':'eth_call','params':[{'to':address,'data':SELECTOR},'latest']}
    r=s.post(url,json=p,timeout=30); r.raise_for_status(); b=r.json(); res=b.get('result') if isinstance(b,dict) else None
    if not isinstance(res,str) or not res.startswith('0x'): raise RuntimeError(str(b))
    return res

def main():
    s=requests.Session(); s.headers.update({'User-Agent':'fluid-fsl-automation/current'})
    now=datetime.now(timezone.utc).isoformat(); rows=[]; failures=[]; nonzero=[]
    for network,chain,address,url in TARGETS:
        result=None; source=None; route_attempts=[]; fallback_attempts=[]
        for a in range(3):
            try:
                r=s.get(url,timeout=30); body=r.json() if r.content else None
                route_attempts.append({'attempt':a+1,'status':r.status_code,'body':body})
                r.raise_for_status(); res=body.get('result') if isinstance(body,dict) else None
                if isinstance(res,str) and res.startswith('0x'): result=res; source='routescan'; break
            except Exception as e:
                route_attempts.append({'attempt':a+1,'error':repr(e)})
            time.sleep(a+1)
        if result is None:
            for rpc in RPCS[chain]:
                try:
                    result=rpc_call(s,rpc,address); source=rpc; fallback_attempts.append({'rpc':rpc,'result':result}); break
                except Exception as e: fallback_attempts.append({'rpc':rpc,'error':repr(e)})
        if result is None:
            failures.append({'network':network,'chain_id':chain,'address':address,'canonical_routescan_url':url,'routescan_attempts':route_attempts,'fallback_attempts':fallback_attempts,'error':'No confirmed eth_call result'})
            continue
        raw=dec32(result)
        row={'network':network,'chain_id':chain,'address':address,'canonical_routescan_url':url,'source':source,'result':result,'raw_int32':raw,'annual_percent':raw/10000,'checked_at_utc':now,'routescan_attempts':route_attempts,'fallback_attempts':fallback_attempts}
        if raw!=0:
            confirms=[]; confirmed=False
            for rpc in RPCS[chain]:
                if rpc==source: continue
                try:
                    r2=rpc_call(s,rpc,address); raw2=dec32(r2); match=(r2.lower()==result.lower() and raw2==raw)
                    confirms.append({'rpc':rpc,'result':r2,'raw_int32':raw2,'match':match})
                    if match: confirmed=True; break
                except Exception as e: confirms.append({'rpc':rpc,'error':repr(e)})
            row['independent_confirmations']=confirms; row['nonzero_confirmed']=confirmed
            if confirmed: nonzero.append(row)
            else: failures.append({**row,'error':'Nonzero not independently confirmed'})
        rows.append(row)
    out={'checked_at_utc':now,'target_count':21,'success_count':21-len(failures),'failure_count':len(failures),'nonzero':nonzero,'results':rows,'failures':failures}
    with open('automation/fsl-current-result.json','w') as f: json.dump(out,f,indent=2)
    print(json.dumps(out,indent=2))
    return 2 if failures else 0
if __name__=='__main__': raise SystemExit(main())

# automation refresh marker: 2026-08-07T19:59:10Z

#!/usr/bin/env python3
import json, os, time, requests
from datetime import datetime, timezone

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
RPCS={1:['https://ethereum-rpc.publicnode.com','https://rpc.ankr.com/eth'],8453:['https://base-rpc.publicnode.com','https://mainnet.base.org'],137:['https://polygon-bor-rpc.publicnode.com','https://polygon-rpc.com'],42161:['https://arbitrum-one-rpc.publicnode.com','https://arb1.arbitrum.io/rpc'],9745:['https://rpc.plasma.to','https://plasma-rpc.publicnode.com']}
s=requests.Session(); s.headers['User-Agent']='fsl-canonical-check/2026-08-19'
def dec32(x):
    v=int(x,16)&0xffffffff
    return v-(1<<32) if v&0x80000000 else v
def routescan(url):
    errs=[]
    for i in range(3):
        try:
            r=s.get(url,timeout=25); r.raise_for_status(); j=r.json(); x=j.get('result')
            if isinstance(x,str) and x.startswith('0x'): return x,'routescan'
            errs.append(str(j))
        except Exception as e: errs.append(repr(e))
        time.sleep(1+i)
    raise RuntimeError(' | '.join(errs))
def rpc(chain,address):
    p={'jsonrpc':'2.0','id':1,'method':'eth_call','params':[{'to':address,'data':SELECTOR},'latest']}
    errs=[]
    for u in RPCS.get(chain,[]):
        try:
            r=s.post(u,json=p,timeout=25); r.raise_for_status(); j=r.json(); x=j.get('result')
            if isinstance(x,str) and x.startswith('0x'): return x,u
            errs.append(u+':'+str(j))
        except Exception as e: errs.append(u+':'+repr(e))
    raise RuntimeError(' | '.join(errs))
checked=datetime.now(timezone.utc).isoformat(); rows=[]; failures=[]
for network,chain,address,url in TARGETS:
    try:
        try: result,source=routescan(url)
        except Exception as e1:
            try: result,source=rpc(chain,address)
            except Exception as e2:
                failures.append({'network':network,'chain_id':chain,'address':address,'url':url,'error':f'routescan={e1}; fallback={e2}'})
                continue
        raw=dec32(result)
        row={'network':network,'chain_id':chain,'address':address,'url':url,'source':source,'result':result,'raw_int32':raw,'annual_percent':raw/10000,'checked_at_utc':checked}
        if raw != 0:
            confirms=[]
            for ru in RPCS.get(chain,[]):
                try:
                    rr,_=rpc(chain,address); confirms.append({'source':ru,'result':rr,'raw_int32':dec32(rr),'match':dec32(rr)==raw}); break
                except Exception as e: confirms.append({'source':ru,'error':repr(e)})
            row['independent_confirmations']=confirms
        rows.append(row)
    except Exception as e:
        failures.append({'network':network,'chain_id':chain,'address':address,'url':url,'error':repr(e)})
out={'checked_at_utc':checked,'target_count':len(TARGETS),'success_count':len(rows),'failure_count':len(failures),'nonzero':[r for r in rows if r['raw_int32']!=0],'results':rows,'failures':failures}
os.makedirs('automation-results',exist_ok=True)
with open('automation-results/fsl-20260819-0853.json','w') as f: json.dump(out,f,indent=2)
print(json.dumps(out,indent=2))

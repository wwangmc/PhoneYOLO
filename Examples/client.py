"""pip install websockets; python Examples/client.py 'ws://IP:8765/detections?token=TOKEN'"""
import argparse
import asyncio
import json
import websockets

async def main(url):
    async for connection in websockets.connect(url, ping_interval=15, ping_timeout=20, max_size=1024*1024):
        try:
            async for payload in connection:
                result=json.loads(payload)
                print(json.dumps(result,ensure_ascii=False),flush=True)
        except websockets.ConnectionClosed:
            print("Disconnected; reconnecting...",flush=True)

if __name__=="__main__":
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("url")
    asyncio.run(main(parser.parse_args().url))

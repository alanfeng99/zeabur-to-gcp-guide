import { BlockList, isIP } from 'node:net';

/** Loopback 與私有網段：部署自己的 proxy 所在的位置。 */
const PRIVATE_NETWORKS = new BlockList();
PRIVATE_NETWORKS.addSubnet('127.0.0.0', 8);
PRIVATE_NETWORKS.addSubnet('10.0.0.0', 8);
PRIVATE_NETWORKS.addSubnet('172.16.0.0', 12);
PRIVATE_NETWORKS.addSubnet('192.168.0.0', 16);
PRIVATE_NETWORKS.addAddress('::1', 'ipv6');
PRIVATE_NETWORKS.addSubnet('fc00::', 7, 'ipv6');

/**
 * Express 的 `trust proxy` 函式：前 `hops` 跳照常信任（和 TRUST_PROXY_HOPS 一樣），
 * 再往前只信任 loopback／私有網段的 proxy。
 *
 * 給不同路徑經過不同層數 proxy 的部署用：公開 API 網域只經過 Traefik 一層，後台網域
 * 經過 cloudflared 與 Traefik 兩層，任何固定層數都會讀錯其中一個（讀成 cloudflared 的
 * 位址，限流與稽核紀錄就全錯）。往回走遇到第一個公開位址（真正的客戶端）就停，客戶端
 * 自己塞在左邊的 X-Forwarded-For 一律不信任。
 *
 * 只有在「從私有位址連得到 API 的只有你自己的 proxy」時才安全。
 *
 * 用法（NestJS／Express）：
 *   app.getHttpAdapter().getInstance().set('trust proxy', trustHopsAndPrivateProxies(1));
 */
export function trustHopsAndPrivateProxies(hops: number): (addr: string, hop: number) => boolean {
  return (addr, hop) => {
    if (hop < hops) return true;
    const family = isIP(addr);
    // 格式不對的 X-Forwarded-For 項目一定不是自己的 proxy
    return family !== 0 && PRIVATE_NETWORKS.check(addr, family === 6 ? 'ipv6' : 'ipv4');
  };
}

// 在 Zeabur 的 API 容器裡執行（由 sync-assets.sh 帶進去）：把 MinIO bucket 裡的每個物件
// 複製到 GCS，key 不變；GCS 上已有同大小的就跳過，所以可以重跑。
// S3_* 是 API 容器原本的 MinIO 設定（你的 app 用別的名稱，例如 MINIO_*、AWS_*，就改下面的
// process.env.*）；DEST_* 是只對 assets bucket 有權限的暫時 HMAC 金鑰。用的是 app 自己的 minio
// 套件：app 用 @aws-sdk 之類的就改寫成那個套件。
// 只印統計數字；失敗時物件名稱只留前綴。
const { Client } = require('/app/node_modules/minio'); // 路徑依 image 調整
const src = new Client({ endPoint: process.env.S3_ENDPOINT, port: +process.env.S3_PORT, useSSL: process.env.S3_USE_SSL === 'true', accessKey: process.env.S3_ACCESS_KEY, secretKey: process.env.S3_SECRET_KEY });
const dst = new Client({ endPoint: 'storage.googleapis.com', port: 443, useSSL: true, accessKey: process.env.DEST_ACCESS_KEY, secretKey: process.env.DEST_SECRET_KEY });
const sb = process.env.S3_BUCKET, db = process.env.DEST_BUCKET;
(async () => {
  const objs = [];
  await new Promise((res, rej) => src.listObjectsV2(sb, '', true).on('data', (o) => objs.push(o)).on('error', rej).on('end', res));
  let copied = 0, skipped = 0, failed = 0;
  for (const o of objs) {
    try {
      let have = null;
      try { have = await dst.statObject(db, o.name); } catch (e) { if (!['NotFound', 'NoSuchKey'].includes(e.code)) throw e; }
      if (have && have.size === o.size) { skipped++; continue; }
      const meta = await src.statObject(sb, o.name);
      await dst.putObject(db, o.name, await src.getObject(sb, o.name), o.size, { 'Content-Type': meta.metaData['content-type'] || 'application/octet-stream' });
      const put = await dst.statObject(db, o.name);
      if (put.size !== o.size) throw new Error(`size mismatch ${put.size} != ${o.size}`);
      copied++;
    } catch (e) { failed++; console.log('FAIL', o.name.replace(/[^/]+$/, '…'), e.code || '', String(e.message).slice(0, 120)); }
  }
  console.log(JSON.stringify({ sourceObjects: objs.length, copied, skipped, failed }));
  process.exitCode = failed > 0 ? 1 : 0;
})().catch((e) => { console.log('FATAL', e.code || '', e.message); process.exitCode = 1; });

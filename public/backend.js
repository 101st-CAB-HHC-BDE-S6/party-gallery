'use strict';

(() => {
  let originPromise;

  async function backendOrigin() {
    if (!location.hostname.toLowerCase().endsWith('.github.io')) return location.origin;
    if (!originPromise) {
      const configUrl = new URL('tunnel-config.json', location.href);
      configUrl.searchParams.set('t', Date.now());
      originPromise = fetch(configUrl, { cache: 'no-store' }).then(async (response) => {
        if (!response.ok) throw new Error('The live event connection is unavailable.');
        const config = await response.json();
        const backend = new URL(config.url);
        if (backend.protocol !== 'https:' || !/^[a-z0-9-]+\.trycloudflare\.com$/i.test(backend.hostname)
            || backend.port || backend.username || backend.password || backend.search || backend.hash) {
          throw new Error('The live event connection settings are invalid.');
        }
        return backend.origin;
      });
    }
    return originPromise;
  }

  window.partyGalleryApi = async (path) => {
    const origin = await backendOrigin();
    return new URL(path.startsWith('/') ? path : `/${path}`, origin).href;
  };
})();

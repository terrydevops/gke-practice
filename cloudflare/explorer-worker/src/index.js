// The public entry of the explorer (docs/esplora-explorer.md): forward every
// request to the cluster through the Workers VPC Service. The service decides
// host and port; the URL scheme picks the protocol, so it is http here even
// though workers.dev is reached over https. Path and query are kept.
export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const target = `http://explorer${url.pathname}${url.search}`;
    return env.EXPLORER.fetch(new Request(target, request));
  },
};

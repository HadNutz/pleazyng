import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';

interface Item { Id: string; Name: string; MediaType?: string; IsFolder?: boolean; }
interface Items { Items: Item[]; TotalRecordCount?: number; }
interface User { Id: string; }
interface Login { AccessToken: string; User: User; }
interface Part { key: string; }
interface Version { Part: Part[]; }
interface PlexItem { key: string; title: string; type: string; ratingKey?: string; Media?: Version[]; }
interface Container { Directory?: PlexItem[]; Metadata?: PlexItem[]; totalSize?: number; size?: number; }
interface PlexReply { MediaContainer: Container; }
export interface Entry { id: string; title: string; playable: boolean; }
export interface Page { entries: Entry[]; more: boolean; }

export class Library {
  private base: string;
  private plex: boolean;
  private secret: string = '';
  private userId: string = '';
  private device: string = util.generateRandomUUID();
  constructor(address: string, plex: boolean) {
    const base = address.trim().replace(/\/+$/, '');
    if (!/^https?:\/\/[^\s/?#@]+(\/[^\s?#]*)?$/i.test(base)) throw new Error('Invalid server address');
    this.base = base;
    this.plex = plex;
  }

  headers(): Record<string, string> {
    const header: Record<string, string> = { 'Accept': 'application/json' };
    if (this.plex) header['X-Plex-Token'] = this.secret;
    else {
      header['Authorization'] = 'MediaBrowser Client="Pleazyng", Device="HarmonyOS", DeviceId="' +
        this.device + '", Version="1.0"' + (this.secret ? ', Token="' + this.secret + '"' : '');
    }
    return header;
  }

  private async request(path: string, body?: string): Promise<string> {
    const request = http.createHttp();
    try {
      const headers = this.headers();
      if (body) headers['Content-Type'] = 'application/json';
      const result = await request.request(this.base + path, {
        method: body ? http.RequestMethod.POST : http.RequestMethod.GET, header: headers,
        extraData: body, expectDataType: http.HttpDataType.STRING, readTimeout: 15000, connectTimeout: 10000,
        usingCache: false, maxLimit: 4194304
      });
      if (result.responseCode !== 200 || typeof result.result !== 'string') throw new Error('Server request failed');
      return result.result;
    } finally { request.destroy(); }
  }

  async login(user: string, credential: string): Promise<void> {
    if (this.plex) { this.secret = credential; return; }
    const data = JSON.parse(await this.request('/Users/AuthenticateByName',
      JSON.stringify({ Username: user, Pw: credential }))) as Login;
    if (!data.User?.Id || !data.AccessToken || /["\r\n]/.test(data.AccessToken)) throw new Error('Sign in failed');
    this.userId = encodeURIComponent(data.User.Id);
    this.secret = data.AccessToken;
  }

  async browse(parent: string, start: number): Promise<Page> {
    const size = 60;
    if (this.plex) {
      const path = parent || '/library/sections';
      const data = (JSON.parse(await this.request(path + '?X-Plex-Container-Start=' + start +
        '&X-Plex-Container-Size=' + size)) as PlexReply).MediaContainer;
      const nodes = data.Metadata ?? data.Directory ?? [];
      const entries: Entry[] = [];
      for (let node of nodes) {
        if (!parent && /^\d+$/.test(node.key)) {
          entries.push({ id: '/library/sections/' + node.key + '/all', title: node.title, playable: false });
        } else if (node.Media?.length && node.Media[0].Part?.length) {
          const part = node.Media[0].Part[0].key;
          if (/^\/library\/parts\//.test(part)) entries.push({ id: part, title: node.title, playable: true });
        } else if (node.ratingKey && /^\d+$/.test(node.ratingKey)) {
          entries.push({ id: '/library/metadata/' + node.ratingKey + '/children', title: node.title, playable: false });
        }
      }
      return { entries: entries, more: nodes.length >= size && start + nodes.length < (data.totalSize ?? 0) };
    }
    const prefix = '/Users/' + this.userId;
    const data = JSON.parse(await this.request(!parent ? prefix + '/Views' :
      prefix + '/Items?ParentId=' + encodeURIComponent(parent) + '&SortBy=SortName&StartIndex=' + start +
      '&Limit=' + size)) as Items;
    const entries: Entry[] = [];
    for (let row of data.Items) {
      if (row.IsFolder || !parent) entries.push({ id: row.Id, title: row.Name, playable: false });
      else if (row.MediaType === 'Video' || row.MediaType === 'Audio') {
        const path = (row.MediaType === 'Audio' ? '/Audio/' : '/Videos/') + encodeURIComponent(row.Id) + '/stream?static=true';
        entries.push({ id: path, title: row.Name, playable: true });
      }
    }
    return { entries: entries, more: !!parent && start + size < (data.TotalRecordCount ?? 0) };
  }

  mediaUrl(entry: Entry): string { return this.base + entry.id; }
}

// Where the native library (keynub_licdongle_flat) comes from.
//
// The path given to setLibraryPath(), then KEYNUB_LICDONGLE_FLAT_LIBRARY in the
// environment, then natives/<platform>/ of an SDK clone from the main module's
// folder, the working directory and (for a local copy of this package) the
// package's own folder upwards, then the bare file name for the system loader.
// A process loads the library once.
import { type Api, SYMBOLS } from "./flat.ts";

/** The native library could not be loaded, or does not fit. */
export class LibraryError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "LibraryError";
  }
}

/** The environment variable that names the library file. */
export const LIBRARY_ENVIRONMENT_VARIABLE = "KEYNUB_LICDONGLE_FLAT_LIBRARY";

const NATIVE_FOLDERS = ["win-x64", "win-x86", "win-arm64", "linux-x64", "linux-arm64", "osx-x64", "osx-arm64"];

let api: Api | undefined;
let loadedPath: string | undefined;
let chosenPath: string | undefined;

/** Names the library file to load. Call it before the first dongle call. */
export function setLibraryPath(path: string): void {
  if (loadedPath !== undefined && loadedPath !== path) {
    throw new LibraryError(`the KeyNub library is already loaded from ${loadedPath}; a process loads it once`);
  }
  chosenPath = path;
}

/** The path in use, or the first candidate when nothing is loaded yet. */
export function libraryPath(): string {
  return loadedPath ?? libraryCandidates()[0];
}

/** The path of the loaded library; undefined before the first call. */
export function loadedLibraryPath(): string | undefined {
  return loadedPath;
}

/** The library's file name on this operating system. */
export function libraryBasename(): string {
  switch (Deno.build.os) {
    case "windows":
      return "keynub_licdongle_flat.dll";
    case "darwin":
      return "libkeynub_licdongle_flat.dylib";
    default:
      return "libkeynub_licdongle_flat.so";
  }
}

function granted(descriptor: Deno.PermissionDescriptor): boolean {
  try {
    return Deno.permissions.querySync(descriptor).state === "granted";
  } catch {
    return false;
  }
}

function isFile(path: string): boolean {
  if (!granted({ name: "read", path })) return false;
  try {
    return Deno.statSync(path).isFile;
  } catch {
    return false;
  }
}

function separator(): string {
  return Deno.build.os === "windows" ? "\\" : "/";
}

function join(...parts: string[]): string {
  return parts.join(separator());
}

function parentOf(dir: string): string {
  const trimmed = dir.replace(/[\\/]+$/, "");
  const at = Math.max(trimmed.lastIndexOf("/"), trimmed.lastIndexOf("\\"));
  if (at < 0) return dir;
  const parent = trimmed.slice(0, at);
  return parent === "" || /^[A-Za-z]:$/.test(parent) ? parent + separator() : parent;
}

function fileUrlFolder(url: string | undefined): string | undefined {
  if (!url || !url.startsWith("file:")) return undefined;
  const path = decodeURIComponent(new URL(url).pathname);
  const native = Deno.build.os === "windows" ? path.replace(/^\/([A-Za-z]:)/, "$1").replaceAll("/", "\\") : path;
  return parentOf(native);
}

/** The paths tried, in order. */
export function libraryCandidates(): string[] {
  if (chosenPath !== undefined) return [chosenPath];
  if (granted({ name: "env", variable: LIBRARY_ENVIRONMENT_VARIABLE })) {
    const fromEnvironment = Deno.env.get(LIBRARY_ENVIRONMENT_VARIABLE);
    if (fromEnvironment) return [fromEnvironment];
  }
  const base = libraryBasename();
  const starts: string[] = [];
  const main = fileUrlFolder(Deno.mainModule);
  if (main) starts.push(main);
  if (granted({ name: "read", path: "." })) starts.push(Deno.cwd());
  const own = fileUrlFolder(import.meta.url);
  if (own) starts.push(own);
  const found: string[] = [];
  for (const start of new Set(starts)) {
    let dir = start;
    for (;;) {
      for (const folder of NATIVE_FOLDERS) {
        const path = join(dir.replace(/[\\/]+$/, ""), "natives", folder, base);
        if (!found.includes(path) && isFile(path)) found.push(path);
      }
      const parent = parentOf(dir);
      if (parent === dir) break;
      dir = parent;
    }
  }
  found.push(base);
  return found;
}

/** The library's functions, loading it on the first call. */
export function loadApi(): Api {
  if (api) return api;
  const reasons: string[] = [];
  for (const path of libraryCandidates()) {
    try {
      api = Deno.dlopen(path, SYMBOLS).symbols;
      loadedPath = path;
      return api;
    } catch (e) {
      reasons.push(`${path} (${e instanceof Error ? e.message : String(e)})`);
    }
  }
  throw new LibraryError(`cannot load the KeyNub library; tried ${reasons.join(", ")}`);
}

import { fileURLToPath, pathToFileURL } from "node:url";

export function pathToUri(filePath: string): string {
  // pathToFileURL handles Windows paths and produces a proper file:// URI.
  return pathToFileURL(filePath).toString();
}

export function uriToPath(uri: string): string {
  try {
    return fileURLToPath(uri);
  } catch {
    // If it's not a file:// URL, best-effort return the original string.
    return uri;
  }
}


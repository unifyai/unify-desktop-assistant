import { Image } from '@/memory/image';
import phash from 'sharp-phash';
import logger from '@/logger';

/**
 * Computes the Perceptual Hash (pHash) for a given image.
 * @returns A 16-character hexadecimal pHash string
 */
export async function computePHash(screenshot: Image): Promise<string> {
    const buffer = Buffer.from(await screenshot.toBase64(), 'base64');
    const bitString = await phash(buffer);
    const hexHash = BigInt("0b" + bitString).toString(16).padStart(16, "0");
    return hexHash;
}

/**
 * Calculates the Hamming distance between two hexadecimal pHash strings.
 * @returns The number of differing bits, or Infinity if inputs are invalid
 */
export function calculateHammingDistance(hexHash1: string, hexHash2: string): number {
    if (!hexHash1 || !hexHash2 || hexHash1.length !== 16 || hexHash2.length !== 16) {
        logger.warn(`Invalid Hamming distance input: h1=${hexHash1}, h2=${hexHash2}`);
        return Infinity;
    }
    try {
        const bigint1 = BigInt(`0x${hexHash1}`);
        const bigint2 = BigInt(`0x${hexHash2}`);
        let diff = bigint1 ^ bigint2;
        let distance = 0;
        while (diff > 0) {
            distance += Number(diff & 1n);
            diff >>= 1n;
        }
        return distance;
    } catch (e) {
        logger.warn(`Hamming distance error: ${(e as Error).message}`);
        return Infinity;
    }
}

/**
 * Calculates the cosine similarity between two embedding vectors.
 * @returns Similarity between -1 (opposite) and 1 (identical), or 0 if invalid
 */
export function calculateCosineSimilarity(vec1: number[] | null, vec2: number[] | null): number {
    if (!vec1 || !vec2 || vec1.length !== vec2.length || vec1.length === 0) {
        logger.warn(`Invalid cosine similarity input: vec1=${vec1?.length}, vec2=${vec2?.length}`);
        return 0;
    }
    
    let dotProduct = 0;
    let norm1 = 0;
    let norm2 = 0;
    
    for (let i = 0; i < vec1.length; i++) {
        dotProduct += vec1[i] * vec2[i];
        norm1 += vec1[i] * vec1[i];
        norm2 += vec2[i] * vec2[i];
    }
    
    const norm1Sqrt = Math.sqrt(norm1);
    const norm2Sqrt = Math.sqrt(norm2);

    if (norm1Sqrt === 0 || norm2Sqrt === 0) {
        logger.warn('Cosine similarity: zero magnitude vector');
        return 0;
    }
    
    const similarity = dotProduct / (norm1Sqrt * norm2Sqrt);
    return Math.max(-1, Math.min(1, similarity));
}
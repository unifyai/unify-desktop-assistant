import { GoogleAuth } from 'google-auth-library';
import logger from '@/logger';

let vertexAuth: GoogleAuth | null = null;
let vertexProject: string | null = null;
let vertexLocation: string = 'us-central1'; // Default location

/**
 * Initialize the Vertex AI client with Google Cloud credentials.
 * Should be called once during agent startup.
 */
export async function initializeVertexClient(): Promise<void> {
    try {
        // Get project ID from environment or from ADC
        vertexProject = process.env.GOOGLE_CLOUD_PROJECT || process.env.GCP_PROJECT || null;
        vertexLocation = process.env.VERTEX_AI_LOCATION || 'us-central1';
        
        // Initialize Google Auth with Application Default Credentials
        vertexAuth = new GoogleAuth({
            scopes: ['https://www.googleapis.com/auth/cloud-platform']
        });

        // If project not in env, try to get it from ADC
        if (!vertexProject) {
            vertexProject = await vertexAuth.getProjectId();
        }

        if (!vertexProject) {
            throw new Error('Could not determine Google Cloud Project ID. Set GOOGLE_CLOUD_PROJECT or configure ADC.');
        }

        logger.info(`Vertex AI client initialized for project: ${vertexProject}, location: ${vertexLocation}`);
    } catch (error) {
        logger.error(`Failed to initialize Vertex AI client: ${(error as Error).message}`);
        throw error;
    }
}

/**
 * Get multimodal embedding for an image using Vertex AI.
 * @param imageBase64 Base64 encoded image string (without data URL prefix)
 * @returns Embedding vector (array of numbers) or null if failed
 */
export async function getEmbeddingForImage(imageBase64: string): Promise<number[] | null> {
    if (!vertexAuth || !vertexProject) {
        logger.error('Vertex AI client not initialized. Call initializeVertexClient() first.');
        return null;
    }

    try {
        // Get access token
        const client = await vertexAuth.getClient();
        const accessToken = await client.getAccessToken();
        
        if (!accessToken.token) {
            logger.error('Failed to get access token for Vertex AI');
            return null;
        }

        // Construct the Vertex AI endpoint for multimodal embeddings
        // Using the multimodalembedding@001 model
        const endpoint = `https://${vertexLocation}-aiplatform.googleapis.com/v1/projects/${vertexProject}/locations/${vertexLocation}/publishers/google/models/multimodalembedding@001:predict`;

        // Prepare the request payload
        const requestBody = {
            instances: [
                {
                    image: {
                        bytesBase64Encoded: imageBase64
                    }
                }
            ]
        };

        // Make the API call
        const response = await fetch(endpoint, {
            method: 'POST',
            headers: {
                'Authorization': `Bearer ${accessToken.token}`,
                'Content-Type': 'application/json'
            },
            body: JSON.stringify(requestBody)
        });

        if (!response.ok) {
            const errorText = await response.text();
            logger.error(`Vertex AI embedding request failed: ${response.status} - ${errorText}`);
            return null;
        }

        const result = await response.json();

        // Extract embedding from response
        // Response structure: { predictions: [{ imageEmbedding: [numbers...] }] }
        if (result.predictions && result.predictions.length > 0 && result.predictions[0].imageEmbedding) {
            const embedding = result.predictions[0].imageEmbedding;
            logger.debug(`Successfully retrieved embedding vector of length ${embedding.length}`);
            return embedding;
        } else {
            logger.error('Unexpected response structure from Vertex AI:', result);
            return null;
        }
    } catch (error) {
        logger.error(`Error getting embedding from Vertex AI: ${(error as Error).message}`);
        return null;
    }
}

/**
 * Test the Vertex AI connection and embedding generation.
 * Useful for debugging and validation.
 */
export async function testVertexConnection(): Promise<boolean> {
    try {
        // Create a small 1x1 test image (base64 encoded white PNG)
        const testImageBase64 = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8/5+hHgAHggJ/PchI7wAAAABJRU5ErkJggg==';
        
        logger.info('Testing Vertex AI connection...');
        const embedding = await getEmbeddingForImage(testImageBase64);
        
        if (embedding && embedding.length > 0) {
            logger.info(`Vertex AI connection test successful. Embedding dimension: ${embedding.length}`);
            return true;
        } else {
            logger.error('Vertex AI connection test failed: no embedding returned');
            return false;
        }
    } catch (error) {
        logger.error(`Vertex AI connection test failed: ${(error as Error).message}`);
        return false;
    }
}


/**
 * Verify MantisBT Connection & Permissions (Read-Only)
 */

const { checkMantisStatus } = require('../mantis-client');

async function testConnection() {
    console.log('🔄 Checking connection to MantisBT (https://mantis.irdsoft.com)...');
    const result = await checkMantisStatus();

    if (result.status === 'CONNECTED') {
        console.log('✅ Connection to MantisBT SUCCESSFUL!');
        console.log(`📡 Status Code: ${result.statusCode}`);
        const losProject = result.projects.find(p => p.id === 5 || p.name === 'LOS system');
        if (losProject) {
            console.log(`📁 Target Project Found: "${losProject.name}" (ID: ${losProject.id})`);
            console.log(`   Description: "${losProject.description}"`);
            console.log(`   Categories: ${losProject.categories.map(c => c.name).join(', ')}`);
        }
    } else {
        console.error('❌ Failed to connect to MantisBT:', result);
    }
}

testConnection().catch(err => console.error(err));

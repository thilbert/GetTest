Param(
    [Parameter (Mandatory = $false)]
    [object] $WebHookData
)
if($WebHookData){
    $body = ConvertFrom-Json -InputObject $WebHookData.RequestBody
    $StorageAccountName = ($body | Select -ExpandProperty "StorageAccountName")
    $FolderName = ($body | Select -ExpandProperty "FolderName")
    $ProjectName = ($body | Select -ExpandProperty "ProjectName")
    $FileSystemName = ($body | Select -ExpandProperty "FileSystemName")
    $dirname = ($body | Select -ExpandProperty "dirname")
    $VaultName = ($body | Select -ExpandProperty "VaultName")
    $ADLSecretName = ($body | Select -ExpandProperty "ADLSecretName")
    $SQLSecretName = ($body | Select -ExpandProperty "SQLSecretName")
}

$connectionName = "AzureRunAsConnection"
try
{
    $servicePrincipalConnection = Get-AutomationConnection -Name $connectionName

    "Logging in to Azure..."
    $connectionResult =  Connect-AzAccount -Tenant $servicePrincipalConnection.TenantID `
                             -ApplicationId $servicePrincipalConnection.ApplicationID   `
                             -CertificateThumbprint $servicePrincipalConnection.CertificateThumbprint `
                             -ServicePrincipal
    "Logged in."
}
catch {
    if (!$servicePrincipalConnection)
    {
        $ErrorMessage = "Connection $connectionName not found."
        throw $ErrorMessage
    } else{
        Write-Error -Message $_.Exception
        throw $_.Exception
    }
}

 
# Retrieve value from Key Vault
$ADLSecretValue = Get-AzKeyVaultSecret -VaultName $VaultName -Name $ADLSecretName -AsPlainText
$SQLSecretValue = Get-AzKeyVaultSecret -VaultName $VaultName -Name $SQLSecretName -AsPlainText


$ctx = New-AzStorageContext -StorageAccountName $StorageAccountName -StorageAccountKey $ADLSecretValue

$instanceName = "SERVER\SQL";
$bufferSize = 8192;

$File = New-TemporaryFile
Remove-Item -path $File -force


$baseExportSql = "EXEC [SSISDB].[catalog].[get_project] @folder_name = $FolderName, @Project_name = $ProjectName;";

$connection = New-Object System.Data.SqlClient.SqlConnection $SQLSecretValue;
$command = New-Object System.Data.SqlClient.SqlCommand;
$command.Connection = $connection;


$connection.Folders | % {
 
    $folder = $_;
    
    $_.Projects | % {

        $project = $_;

        $project.Packages | % {

            "$($folder.Name)\$($project.Name)\$($_.Name)";

        }

        # create a folder for it
        $path = "$($ENV:Temp)\$($File.Name)\$($instanceName)\$($folder.Name)\$($project.Name)";
        New-Item -ItemType Directory -Force -Path $path | Out-Null;
        $fileName = "$($path)\$($project.Name).zip";
        Write-Host $fileName
        if ($connection.State -ne "Open")
        {
            $connection.Open();
        }

        $fileOutput = [array]::CreateInstance('Byte', $bufferSize)

        $command.CommandText = $baseExportSql -f $folder.Name, $project.Name;
        $reader = $command.ExecuteReader();

        while($reader.Read())
        {
            $fileStream = New-Object System.IO.FileStream($fileName), Create, Write;
            $binaryWriter = New-Object System.IO.BinaryWriter $fileStream;
               
            $start = 0;            
            
            $received = $reader.GetBytes(0, $start, $fileOutput, 0, $bufferSize - 1);
    
            while ($received -gt 0)
            {            
               $binaryWriter.Write($fileOutput, 0, $received);
               $binaryWriter.Flush();
               $start += $received;
                           
               $received = $reader.GetBytes(0, $start, $fileOutput, 0, $bufferSize - 1);
            }            
           
            $binaryWriter.Close();       
            $fileStream.Close();
        }

        $reader.Close();
    }

}

if ($connection.State -eq "Open")
{
    $connection.Close();
}


Expand-Archive -LiteralPath $fileName -DestinationPath "$($ENV:Temp)\UnZipSSIS\folder"

$folderContent = Get-ChildItem -Path "$($ENV:Temp)\UnZipSSIS\folder\" -Name

foreach ($file in $folderContent){
    $destPath = $dirname + (Get-Item "$($ENV:Temp)\UnZipSSIS\folder\$file").Name
    New-AzDataLakeGen2Item -Context $ctx -FileSystem $FileSystemName -Path $destPath -Source "$($ENV:Temp)\UnZipSSIS\folder\$file" -Force
}

if($WebHookData){
    $body = ConvertFrom-Json -InputObject $WebHookData.RequestBody
    $Uri = ($body | Select -ExpandProperty "callBackUri")
    Invoke-WebRequest -Uri $Uri -Method Post
}
